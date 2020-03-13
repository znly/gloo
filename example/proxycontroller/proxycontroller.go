package main

// all the import's we'll need for this controller
import (
	"context"
	"io/ioutil"
	"log"
	"os"
	"strings"
	"time"

	"github.com/gogo/protobuf/types"
	"github.com/solo-io/gloo/projects/gloo/pkg/api/v1/options/consul"

	"github.com/hashicorp/consul/api"
	"github.com/solo-io/gloo/pkg/utils/settingsutil"
	v1 "github.com/solo-io/gloo/projects/gloo/pkg/api/v1"
	matchers "github.com/solo-io/gloo/projects/gloo/pkg/api/v1/core/matchers"
	"github.com/solo-io/gloo/projects/gloo/pkg/api/v1/options/static"
	"github.com/solo-io/gloo/projects/gloo/pkg/bootstrap"
	"github.com/solo-io/go-utils/contextutils"
	"github.com/solo-io/go-utils/kubeutils"
	"github.com/solo-io/solo-kit/pkg/api/v1/clients"
	"github.com/solo-io/solo-kit/pkg/api/v1/clients/factory"
	"github.com/solo-io/solo-kit/pkg/api/v1/clients/kube"
	core "github.com/solo-io/solo-kit/pkg/api/v1/resources/core"
	"go.uber.org/zap"

	// import for GKE
	_ "k8s.io/client-go/plugin/pkg/client/auth/gcp"
)

var (
	labels = map[string]string{"example_created_by": "example_controller"}
)

func main() {
	run()
}

func run() {
	// root context for the whole thing
	ctx := context.Background()
	setupNamespace := "gloo-system"
	inKube := false
	if data, err := ioutil.ReadFile("/var/run/secrets/kubernetes.io/serviceaccount/namespace"); err == nil {
		if ns := strings.TrimSpace(string(data)); len(ns) > 0 {
			setupNamespace = ns
			inKube = true
		}
	}
	// initialize Gloo API clients
	upstreamClient, proxyClient := initGlooClients(ctx)

	setupDir := ""
	settingsClient, err := kubeOrFileSettingsClient(ctx, setupNamespace, setupDir)
	must(err)
	err = settingsClient.Register()
	must(err)

	settings, err := settingsClient.Read("gloo-system", "default", clients.ReadOpts{})
	must(err)
	if !inKube {
		// if not in kube, assume we are doing local dev
		settings.Consul.Address = "127.0.0.1:8500"
	}
	consulClient, err := bootstrap.ConsulClientForSettings(ctx, settings)
	must(err)

	// start a watch on upstreams. we'll use this as our trigger
	// whenever upstreams are modified, we'll trigger our sync function
	upstreamWatch, watchErrors, initError := upstreamClient.Watch("gloo-system",
		clients.WatchOpts{Ctx: ctx})
	must(initError)

	// our "event loop". an event occurs whenever the list of upstreams has been updated
	for {
		select {
		// if we error during watch, just exit
		case err := <-watchErrors:
			must(err)
		// process a new upstream list
		case newUpstreamList := <-upstreamWatch:
			// we received a new list of upstreams from our watch,
			resync(ctx, setupNamespace, newUpstreamList, proxyClient, upstreamClient, consulClient)
		}
	}
}

// we received a new list of upstreams! regenerate the desired proxy
// and write it as a CRD to Kubernetes
func resync(ctx context.Context, setupNamespace string, upstreams v1.UpstreamList, client v1.ProxyClient, upstreamClient v1.UpstreamClient, consulClient *api.Client) {
	desiredProxy := makeDesiredProxy(setupNamespace, upstreams, upstreamClient, consulClient)

	// see if the proxy exists. if yes, update; if no, create
	existingProxy, err := client.Read(
		desiredProxy.Metadata.Namespace,
		desiredProxy.Metadata.Name,
		clients.ReadOpts{Ctx: ctx})

	// proxy exists! this is an update, not a create
	if err == nil {

		// sleep for 1s as Gloo may be re-validating our proxy, which can cause resource version to change
		time.Sleep(time.Second)

		// ensure resource version is the latest
		existingProxy, err = client.Read(
			desiredProxy.Metadata.Namespace,
			desiredProxy.Metadata.Name,
			clients.ReadOpts{Ctx: ctx})
		must(err)

		// update the resource version on our desired proxy
		desiredProxy.Metadata.ResourceVersion = existingProxy.Metadata.ResourceVersion
	}

	// write!
	written, err := client.Write(desiredProxy,
		clients.WriteOpts{Ctx: ctx, OverwriteExisting: true})

	must(err)

	log.Printf("wrote proxy object: %+v\n", written)
}

func initGlooClients(ctx context.Context) (v1.UpstreamClient, v1.ProxyClient) {
	// root rest config
	restConfig, err := kubeutils.GetConfig(
		os.Getenv("KUBERNETES_MASTER_URL"),
		os.Getenv("KUBECONFIG"))
	must(err)

	// wrapper for kubernetes shared informer factory
	cache := kube.NewKubeCache(ctx)

	// initialize the CRD client for Gloo Upstreams
	upstreamClient, err := v1.NewUpstreamClient(&factory.KubeResourceClientFactory{
		Crd:             v1.UpstreamCrd,
		Cfg:             restConfig,
		SharedCache:     cache,
		SkipCrdCreation: true,
	})
	must(err)

	// registering the client registers the type with the client cache
	err = upstreamClient.Register()
	must(err)

	// initialize the CRD client for Gloo Proxies
	proxyClient, err := v1.NewProxyClient(&factory.KubeResourceClientFactory{
		Crd:             v1.ProxyCrd,
		Cfg:             restConfig,
		SharedCache:     cache,
		SkipCrdCreation: true,
	})
	must(err)

	// registering the client registers the type with the client cache
	err = proxyClient.Register()
	must(err)

	return upstreamClient, proxyClient
}

// in this function we'll generate an opinionated
// proxy object with a routes for each of our upstreams
func makeDesiredProxy(setupNamespace string, upstreams v1.UpstreamList, upstreamClient v1.UpstreamClient, consulClient *api.Client) *v1.Proxy {

	// each virtual host represents the table of routes for a given
	// domain or set of domains.
	// in this example, we'll create one virtual host
	// for each upstream.
	var virtualHosts []*v1.VirtualHost

	for _, upstream := range upstreams {
		if consulUs := upstream.GetConsul(); consulUs != nil {
			virtualHosts = append(virtualHosts, getConsulVhosts(upstream, consulUs, upstreamClient, consulClient)...)
		}
	}

	desiredProxy := &v1.Proxy{
		// metadata will be translated to Kubernetes ObjectMeta
		Metadata: core.Metadata{
			Namespace: setupNamespace,
			Name:      "my-cool-proxy",
			Labels:    labels,
		},

		// we have the option of creating multiple listeners,
		// but for the purpose of this example we'll just use one
		Listeners: []*v1.Listener{{
			// logical name for the listener
			Name: "aggregated-listener",

			// instruct envoy to bind to all interfaces on port 8080
			BindAddress: "::", BindPort: 8080,

			// at this point you determine what type of listener
			// to use. here we'll be using the HTTP Listener
			// other listener types are currently unsupported,
			// but future
			ListenerType: &v1.Listener_HttpListener{
				HttpListener: &v1.HttpListener{
					// insert our list of virtual hosts here
					VirtualHosts: virtualHosts,
				},
			}},
		},
	}

	return desiredProxy
}

func getDesiredConsulUpstream(upstream *v1.Upstream, consulClient *api.Client) *v1.Upstream {
	consulUs := upstream.GetConsul()
	if consulUs == nil {
		return nil
	}

	var hosts []*static.Host
	for _, dc := range consulUs.GetDataCenters() {
		queryOpts := &api.QueryOptions{Datacenter: dc, RequireConsistent: true}
		svcs, _, err := consulClient.Catalog().Service(consulUs.GetServiceName(), "", queryOpts)
		must(err)
		for _, svc := range svcs {
			hosts = append(hosts, &static.Host{
				Addr: svc.ServiceAddress,
				Port: uint32(svc.ServicePort),
			})
		}
	}

	return &v1.Upstream{
		Metadata: core.Metadata{
			Name:      upstream.GetMetadata().Name + "-static",
			Namespace: upstream.GetMetadata().Namespace,
			Labels:    labels,
			/*
				OwnerReferences: []*core.Metadata_OwnerReference{
					&core.Metadata_OwnerReference{
						Kind:       "Upstream",
						ApiVersion: "gloo.solo.io/v1",
						Name:       upstream.GetMetadata().Name,
						UUID: ...,
					},
				},
			*/
		},
		UpstreamType: &v1.Upstream_Static{
			Static: &static.UpstreamSpec{
				Hosts: hosts,
			},
		},
	}

}

func getConsulVhosts(upstream *v1.Upstream, consulUs *consul.UpstreamSpec, upstreamClient v1.UpstreamClient, consulClient *api.Client) []*v1.VirtualHost {
	var virtualHosts []*v1.VirtualHost

	desiredUpstream := getDesiredConsulUpstream(upstream, consulClient)

	_, err := upstreamClient.Write(desiredUpstream, clients.WriteOpts{OverwriteExisting: true})
	if err != nil {
		us, err := upstreamClient.Read(desiredUpstream.Metadata.Namespace, desiredUpstream.Metadata.Name, clients.ReadOpts{})
		desiredUpstream.Metadata.ResourceVersion = us.GetMetadata().ResourceVersion
		_, err = upstreamClient.Write(desiredUpstream, clients.WriteOpts{OverwriteExisting: true})
		must(err)
	}
	virtualHosts = append(virtualHosts, vhostForUpstream(desiredUpstream, consulUs.ServiceName))
	return virtualHosts
}

func vhostForUpstream(upstream *v1.Upstream, host string) *v1.VirtualHost {
	upstreamRef := upstream.Metadata.Ref()
	// create a virtual host for each upstream
	return &v1.VirtualHost{
		// logical name of the virtual host, should be unique across vhosts
		Name: upstream.Metadata.Name,

		// the domain will be our "matcher".
		// requests with the Host header equal to the upstream name
		// will be routed to this upstream
		Domains: []string{upstream.Metadata.Name},

		// we'll create just one route designed to match any request
		// and send it to the upstream for this domain
		Routes: []*v1.Route{{
			// use a basic catch-all matcher
			Matchers: []*matchers.Matcher{
				&matchers.Matcher{
					PathSpecifier: &matchers.Matcher_Prefix{
						Prefix: "/",
					},
				},
			},

			Options: &v1.RouteOptions{
				HostRewriteType: &v1.RouteOptions_AutoHostRewrite{AutoHostRewrite: &types.BoolValue{Value: true}},
			},

			// tell Gloo where to send the requests
			Action: &v1.Route_RouteAction{
				RouteAction: &v1.RouteAction{
					Destination: &v1.RouteAction_Single{
						// single destination
						Single: &v1.Destination{
							DestinationType: &v1.Destination_Upstream{
								// a "reference" to the upstream, which is a Namespace/Name tuple
								Upstream: &upstreamRef,
							},
						},
					},
				},
			},
		}},
	}
}

// make our lives easy
func must(err error) {
	if err != nil {
		panic(err)
	}
}

func kubeOrFileSettingsClient(ctx context.Context, setupNamespace, settingsDir string) (v1.SettingsClient, error) {
	if settingsDir != "" {
		contextutils.LoggerFrom(ctx).Infow("using filesystem for settings", zap.String("directory", settingsDir))
		return v1.NewSettingsClient(&factory.FileResourceClientFactory{
			RootDir: settingsDir,
		})
	}
	cfg, err := kubeutils.GetConfig("", "")
	if err != nil {
		return nil, err
	}
	return v1.NewSettingsClient(&factory.KubeResourceClientFactory{
		Crd:                v1.SettingsCrd,
		Cfg:                cfg,
		SharedCache:        kube.NewKubeCache(ctx),
		NamespaceWhitelist: []string{setupNamespace},
		SkipCrdCreation:    settingsutil.GetSkipCrdCreation(),
	})
}
