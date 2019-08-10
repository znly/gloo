package gateway_test

import (
	"context"
	"fmt"
	"time"

	. "github.com/onsi/ginkgo"
	. "github.com/onsi/gomega"
	"k8s.io/client-go/rest"

	gatewayv1 "github.com/solo-io/gloo/projects/gateway/pkg/api/v1"
	"github.com/solo-io/gloo/projects/gateway/pkg/translator"
	gloov1 "github.com/solo-io/gloo/projects/gloo/pkg/api/v1"
	"github.com/solo-io/go-utils/kubeutils"
	"github.com/solo-io/go-utils/testutils"
	"github.com/solo-io/go-utils/testutils/helper"
	"github.com/solo-io/solo-kit/pkg/api/v1/clients"
	"github.com/solo-io/solo-kit/pkg/api/v1/clients/factory"
	"github.com/solo-io/solo-kit/pkg/api/v1/clients/kube"
	"github.com/solo-io/solo-kit/pkg/api/v1/resources/core"
)

var _ = Describe("Load", func() {

	const (
		gatewayProxy = translator.GatewayProxyName
		gatewayPort  = int(80)
	)

	var (
		ctx    context.Context
		cancel context.CancelFunc
		cfg    *rest.Config
		cache  kube.SharedCache

		virtualServiceClient gatewayv1.VirtualServiceClient
		upstreamClient       gloov1.UpstreamClient
	)
	var _ = BeforeEach(StartTestHelper)
	var _ = AfterEach(TearDownTestHelper)

	BeforeEach(func() {
		ctx, cancel = context.WithCancel(context.Background())

		var err error
		cfg, err = kubeutils.GetConfig("", "")
		Expect(err).NotTo(HaveOccurred())

		cache = kube.NewKubeCache(ctx)
		virtualServiceClientFactory := &factory.KubeResourceClientFactory{
			Crd:         gatewayv1.VirtualServiceCrd,
			Cfg:         cfg,
			SharedCache: cache,
		}
		upstreamClientFactory := &factory.KubeResourceClientFactory{
			Crd:         gloov1.UpstreamCrd,
			Cfg:         cfg,
			SharedCache: cache,
		}

		virtualServiceClient, err = gatewayv1.NewVirtualServiceClient(virtualServiceClientFactory)
		Expect(err).NotTo(HaveOccurred())
		err = virtualServiceClient.Register()
		Expect(err).NotTo(HaveOccurred())

		upstreamClient, err = gloov1.NewUpstreamClient(upstreamClientFactory)
		Expect(err).NotTo(HaveOccurred())
		err = upstreamClient.Register()
		Expect(err).NotTo(HaveOccurred())

	})
	AfterEach(func() {
		cancel()
	})

	It("should process 200 services", func() {
		err := testutils.Kubectl("create", "deployment", "-n", testHelper.InstallNamespace, "--image", "soloio/petstore-example:latest", "petstore")
		Expect(err).NotTo(HaveOccurred())
		var lastname string
		for i := 0; i < 200; i++ {
			lastname = fmt.Sprintf("petstore-svc-%d", i)
			err = testutils.Kubectl("-n", testHelper.InstallNamespace, "expose", "deployment", "petstore", "--name", lastname, "--port", "8080")
			Expect(err).NotTo(HaveOccurred())
		}
		// we now have 200 services.
		// lets route to the last one and see when gloo responds
		virtualServiceClient.Write(&gatewayv1.VirtualService{
			Metadata: core.Metadata{
				Name:      "default",
				Namespace: testHelper.InstallNamespace,
			},
			VirtualHost: &gloov1.VirtualHost{
				Routes: []*gloov1.Route{
					{
						Matcher: &gloov1.Matcher{
							PathSpecifier: &gloov1.Matcher_Prefix{
								Prefix: "/",
							},
						},
						Action: &gloov1.Route_RouteAction{
							RouteAction: &gloov1.RouteAction{
								Destination: &gloov1.RouteAction_Single{
									Single: &gloov1.Destination{
										DestinationType: &gloov1.Destination_Kube{
											Kube: &gloov1.KubernetesServiceDestination{
												Ref: core.ResourceRef{
													Name:      lastname,
													Namespace: testHelper.InstallNamespace,
												},
												Port: 8080,
											},
										},
									},
								},
							},
						},
					},
				},
			},
		}, clients.WriteOpts{})

		testHelper.CurlEventuallyShouldRespond(helper.CurlOpts{
			Protocol:          "http",
			Path:              "/api/pets/1",
			Method:            "GET",
			Host:              gatewayProxy,
			Service:           gatewayProxy,
			Port:              gatewayPort,
			ConnectionTimeout: 1, // this is important, as sometimes curl hangs
			WithoutStats:      true,
		}, `{"id":1,"name":"Dog","status":"available"}`, 1, 60*time.Second, 1*time.Second)

	})

})
