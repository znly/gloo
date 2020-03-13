module proxycontroller

go 1.13

require (
	code.cloudfoundry.org/bytefmt v0.0.0-20180906201452-2aa6f33b730c // indirect
	github.com/Azure/azure-sdk-for-go v37.1.0+incompatible // indirect
	github.com/Azure/go-autorest/autorest/azure/auth v0.4.2 // indirect
	github.com/Azure/go-autorest/autorest/to v0.3.0 // indirect
	github.com/Azure/go-autorest/autorest/validation v0.2.0 // indirect
	github.com/DataDog/datadog-go v3.3.0+incompatible // indirect
	github.com/SermoDigital/jose v0.9.1 // indirect
	github.com/aliyun/alibaba-cloud-sdk-go v1.60.287 // indirect
	github.com/apple/foundationdb/bindings/go v0.0.0-20191214003451-5d1974539aa9 // indirect
	github.com/chai2010/gettext-go v0.0.0-20170215093142-bf70f2a70fb1 // indirect
	github.com/cockroachdb/cockroach-go v0.0.0-20190925194419-606b3d062051 // indirect
	github.com/denisenkom/go-mssqldb v0.0.0-20191128021309-1d7a30a10f73 // indirect
	github.com/go-ldap/ldap v3.0.3+incompatible // indirect
	github.com/gocql/gocql v0.0.0-20191126110522-1982a06ad6b9 // indirect
	github.com/hashicorp/consul v1.6.2 // indirect
	github.com/hashicorp/consul/api v1.3.0
	github.com/hashicorp/go-gcp-common v0.6.0 // indirect
	github.com/hashicorp/go-memdb v1.0.4 // indirect
	github.com/hashicorp/nomad/api v0.0.0-20191213172644-7700d38457f3 // indirect
	github.com/hashicorp/vault v1.3.0 // indirect
	github.com/jackc/pgconn v1.1.0 // indirect
	github.com/jefferai/jsonx v1.0.1 // indirect
	github.com/joyent/triton-go v1.7.0 // indirect
	github.com/keybase/go-crypto v0.0.0-20190828182435-a05457805304 // indirect
	github.com/michaelklishin/rabbit-hole v1.5.0 // indirect
	github.com/ncw/swift v1.0.49 // indirect
	github.com/pierrec/cmdflag v0.0.2 // indirect
	github.com/samuel/go-zookeeper v0.0.0-20190923202752-2cc03de413da // indirect
	github.com/schollz/progressbar/v2 v2.12.1 // indirect
	github.com/solo-io/gloo v1.3.12 // change to update Gloo version to build against
	github.com/solo-io/go-utils v0.14.1
	github.com/solo-io/solo-kit v0.13.2
	github.com/technosophos/moniker v0.0.0-20180509230615-a5dbd03a2245 // indirect
	github.com/ugorji/go v1.1.5-pre // indirect
	go.etcd.io/etcd v3.3.18+incompatible // indirect
	go.uber.org/zap v1.13.0
	gopkg.in/mgo.v2 v2.0.0-20190816093944-a6b53ec6cb22 // indirect
	k8s.io/client-go v11.0.0+incompatible
)

replace (
	github.com/Azure/go-autorest => github.com/Azure/go-autorest v13.0.0+incompatible
	github.com/Sirupsen/logrus => github.com/sirupsen/logrus v1.4.2
	github.com/docker/docker => github.com/moby/moby v0.7.3-0.20190826074503-38ab9da00309
	k8s.io/api => k8s.io/api v0.0.0-20191004120104-195af9ec3521
	k8s.io/apiextensions-apiserver => k8s.io/apiextensions-apiserver v0.0.0-20191204090712-e0e829f17bab
	k8s.io/apimachinery => k8s.io/apimachinery v0.0.0-20191028221656-72ed19daf4bb
	k8s.io/apiserver => k8s.io/apiserver v0.0.0-20191109104512-b243870e034b
	k8s.io/cli-runtime => k8s.io/cli-runtime v0.0.0-20191004123735-6bff60de4370
	k8s.io/client-go => k8s.io/client-go v0.0.0-20191016111102-bec269661e48
	k8s.io/cloud-provider => k8s.io/cloud-provider v0.0.0-20191004125000-f72359dfc58e
	k8s.io/cluster-bootstrap => k8s.io/cluster-bootstrap v0.0.0-20191004124811-493ca03acbc1
	k8s.io/code-generator => k8s.io/code-generator v0.0.0-20191004115455-8e001e5d1894
	k8s.io/component-base => k8s.io/component-base v0.0.0-20191004121439-41066ddd0b23
	k8s.io/cri-api => k8s.io/cri-api v0.0.0-20190828162817-608eb1dad4ac
	k8s.io/csi-translation-lib => k8s.io/csi-translation-lib v0.0.0-20191004125145-7118cc13aa0a
	k8s.io/gengo => k8s.io/gengo v0.0.0-20190822140433-26a664648505
	k8s.io/heapster => k8s.io/heapster v1.2.0-beta.1
	k8s.io/klog => github.com/stefanprodan/klog v0.0.0-20190418165334-9cbb78b20423
	k8s.io/kube-aggregator => k8s.io/kube-aggregator v0.0.0-20191104231939-9e18019dec40
	k8s.io/kube-controller-manager => k8s.io/kube-controller-manager v0.0.0-20191004124629-b9859bb1ce71
	k8s.io/kube-openapi => k8s.io/kube-openapi v0.0.0-20190816220812-743ec37842bf
	k8s.io/kube-proxy => k8s.io/kube-proxy v0.0.0-20191004124112-c4ee2f9e1e0a
	k8s.io/kube-scheduler => k8s.io/kube-scheduler v0.0.0-20191004124444-89f3bbd82341
	k8s.io/kubectl => k8s.io/kubectl v0.0.0-20191004125858-14647fd13a8b
	k8s.io/kubelet => k8s.io/kubelet v0.0.0-20191004124258-ac1ea479bd3a
	k8s.io/legacy-cloud-providers => k8s.io/legacy-cloud-providers v0.0.0-20191203122058-2ae7e9ca8470
	k8s.io/metrics => k8s.io/metrics v0.0.0-20191004123543-798934cf5e10
	k8s.io/node-api => k8s.io/node-api v0.0.0-20191004125527-f5592a7bd6b6
	k8s.io/repo-infra => k8s.io/repo-infra v0.0.0-20181204233714-00fe14e3d1a3
	k8s.io/sample-apiserver => k8s.io/sample-apiserver v0.0.0-20191028231949-ceef03da3009
	k8s.io/sample-cli-plugin => k8s.io/sample-cli-plugin v0.0.0-20191004123926-88de2937c61b
	k8s.io/sample-controller => k8s.io/sample-controller v0.0.0-20191004122958-d040c2be0d0b
	k8s.io/utils => k8s.io/utils v0.0.0-20190801114015-581e00157fb1
)
