package install

import (
	"fmt"
	"github.com/pkg/errors"
	"github.com/solo-io/gloo/projects/gloo/cli/pkg/constants"
	"github.com/solo-io/gloo/projects/gloo/cli/pkg/flagutils"
	_ "k8s.io/client-go/plugin/pkg/client/auth"

	"github.com/solo-io/gloo/projects/gloo/cli/pkg/cmd/options"
	"github.com/spf13/cobra"
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

	return &glooInstall.GlooInstallSpec{
		HelmArchiveUri:    helmChartArchiveUri,
		ProductName:       "glooe",
		ValueFileName:     "",
		ExtraValues:       extraValues,
		ExcludeResources:  getExcludeExistingPVCs(opts.Install.Namespace),
		UserValueFileName: opts.Install.HelmChartValues,
	}, nil
}