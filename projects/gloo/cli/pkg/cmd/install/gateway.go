package install

import (
	"fmt"
	"github.com/pkg/errors"
	"github.com/solo-io/gloo/pkg/cliutil/install"
	"github.com/solo-io/gloo/projects/gloo/cli/pkg/constants"
	"github.com/solo-io/gloo/projects/gloo/cli/pkg/flagutils"
	"github.com/solo-io/go-utils/kubeutils"
	v1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/client-go/kubernetes"
	_ "k8s.io/client-go/plugin/pkg/client/auth"

	"github.com/solo-io/gloo/projects/gloo/cli/pkg/cmd/options"
	"github.com/spf13/cobra"

	kubeerrors "k8s.io/apimachinery/pkg/api/errors"
)

const (
	GlooEHelmRepoTemplate = "https://storage.googleapis.com/gloo-ee-helm/charts/gloo-ee-%s.tgz"
)

func gatewayCmd(opts *options.Options) *cobra.Command {
	cmd := &cobra.Command{
		Use:    "gateway",
		Short:  "install the Gloo Gateway on kubernetes",
		Long:   "requires kubectl to be installed",
		PreRun: setVerboseMode(opts),
		RunE: func(cmd *cobra.Command, args []string) error {
			if err := installGloo(opts, constants.GatewayValuesFileName); err != nil {
				return errors.Wrapf(err, "installing gloo in gateway mode")
			}
			return nil
		},
	}
	pflags := cmd.PersistentFlags()
	flagutils.AddInstallFlags(pflags, &opts.Install)
	return cmd
}


// enterprise
func GetEnterpriseInstallSpec(opts *options.Options) (*GlooInstallSpec, error) {
	glooEVersion, err := getGlooVersion(opts)
	if err != nil {
		return nil, err
	}

	// Get location of Gloo helm chart
	helmChartArchiveUri := fmt.Sprintf(GlooEHelmRepoTemplate, glooEVersion)
	if helmChartOverride := opts.Install.HelmChartOverride; helmChartOverride != "" {
		helmChartArchiveUri = helmChartOverride
	}

	extraValues := map[string]interface{}{
		"license_key": opts.Install.LicenseKey,
	}

	if opts.Install.Upgrade {
		extraValues["gloo"] = map[string]interface{}{
			"gateway": map[string]interface{}{
				"upgrade": "true",
			},
		}
	} else {
		extraValues["gloo"] = map[string]interface{}{
			"namespace": map[string]interface{}{
				"create": "true",
			},
		}
	}

	return &GlooInstallSpec{
		HelmArchiveUri:    helmChartArchiveUri,
		ProductName:       "glooe",
		ValueFileName:     "",
		ExtraValues:       extraValues,
		ExcludeResources:  getExcludeExistingPVCs(opts.Install.Namespace),
		UserValueFileName: opts.Install.HelmChartValues,
	}, nil
}

const PersistentVolumeClaim = "PersistentVolumeClaim"

func getExcludeExistingPVCs(namespace string) install.ResourceMatcherFunc {
	return func(resource install.ResourceType) (bool, error) {
		cfg, err := kubeutils.GetConfig("", "")
		if err != nil {
			return false, err
		}
		kubeClient, err := kubernetes.NewForConfig(cfg)
		if err != nil {
			return false, err
		}

		// If this is a PVC, check if it already exists. If so, exclude this resource from the manifest.
		// We don't want to overwrite existing PVCs.
		if resource.TypeMeta.Kind == PersistentVolumeClaim {

			_, err := kubeClient.CoreV1().PersistentVolumeClaims(namespace).Get(resource.Metadata.Name, v1.GetOptions{})
			if err != nil {
				if !kubeerrors.IsNotFound(err) {
					return false, errors.Wrapf(err, "retrieving %s: %s.%s", PersistentVolumeClaim, namespace, resource.Metadata.Name)
				}
			} else {
				// The PVC exists, exclude it from manifest
				return true, nil
			}
		}
		return false, nil
	}
}