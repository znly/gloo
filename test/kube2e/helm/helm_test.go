package helm_test

import (
	. "github.com/onsi/ginkgo"
	. "github.com/onsi/gomega"
	"github.com/solo-io/gloo/projects/gloo/cli/pkg/cmd/version"
	"github.com/solo-io/gloo/projects/gloo/cli/pkg/helpers"
	"github.com/solo-io/gloo/projects/gloo/pkg/defaults"
	"github.com/solo-io/gloo/test/kube2e"
	"github.com/solo-io/solo-kit/pkg/api/v1/clients"
	_ "k8s.io/client-go/plugin/pkg/client/auth/gcp"
)

var _ = Describe("Kube2e: helm", func() {

	It("uses helm to upgrade to a higher 1.3.x version without errors", func() {

		// check that the version is 1.3.0
		AssertGlooVersion(testHelper.InstallNamespace, "1.3.0")

		// upgrade to v1.3.14
		runAndCleanCommand("helm", "upgrade", "gloo", "gloo/gloo",
			"-n", testHelper.InstallNamespace,
			"--version", "v1.3.14")

		// check that the version is 1.3.14 as expected
		AssertGlooVersion(testHelper.InstallNamespace, "1.3.14")

		kube2e.GlooctlCheckEventuallyHealthy(testHelper)
	})

	It("uses helm to update the settings without errors", func() {

		// check that the setting is the default to start
		client := helpers.MustSettingsClient()
		settings, err := client.Read(testHelper.InstallNamespace, defaults.SettingsName, clients.ReadOpts{})
		Expect(err).To(BeNil())
		Expect(settings.GetGloo().GetInvalidConfigPolicy().GetInvalidRouteResponseCode()).To(Equal(uint32(404)))

		// update the settings with `helm upgrade`
		runAndCleanCommand("helm", "upgrade", "gloo", "gloo/gloo",
			"-n", testHelper.InstallNamespace,
			"--set", "settings.invalidConfigPolicy.invalidRouteResponseCode=400")

		// check that the setting updated
		settings, err = client.Read(testHelper.InstallNamespace, defaults.SettingsName, clients.ReadOpts{})
		Expect(err).To(BeNil())
		Expect(settings.GetGloo().GetInvalidConfigPolicy().GetInvalidRouteResponseCode()).To(Equal(uint32(400)))

		kube2e.GlooctlCheckEventuallyHealthy(testHelper)
	})

})

func AssertGlooVersion(namespace string, v string) {
	glooVersion, err := version.GetClientServerVersions(version.NewKube(namespace))
	Expect(err).To(BeNil())
	Expect(len(glooVersion.GetServer())).To(Equal(1))
	for _, container := range glooVersion.GetServer()[0].GetKubernetes().GetContainers() {
		Expect(container.Tag).To(Equal(v))
	}
}
