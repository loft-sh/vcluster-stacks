// gpu-burn-in-recorder records gpu-burn-in Stack results on the servers they qualified. It runs on
// the vCluster Platform cluster. See ../README.md#recorder.
package main

import (
	"flag"
	"os"
	"strings"
	"time"

	"github.com/loft-sh/vcluster-stacks/community-stacks/gpu-burn-in/recorder/internal/qualify"
	"k8s.io/apimachinery/pkg/runtime"
	clientgoscheme "k8s.io/client-go/kubernetes/scheme"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/healthz"
	"sigs.k8s.io/controller-runtime/pkg/log/zap"
	ctrlmetrics "sigs.k8s.io/controller-runtime/pkg/metrics"
	metricsserver "sigs.k8s.io/controller-runtime/pkg/metrics/server"
)

func main() {
	var (
		cfg             qualify.Config
		templates       string
		target          string
		netboxTokenFile string
		metricsAddr     string
		probeAddr       string
		leaderElect     bool
		topology        string
	)
	flag.StringVar(&templates, "templates", "gpu-burn-in", "Comma-separated StackTemplate names whose instances are recorded.")
	flag.StringVar(&cfg.LabelDomain, "label-domain", "gpu-qualification.example.com", "Domain of the result label and annotations. Not a vcluster.com or loft.sh domain.")
	flag.StringVar(&target, "target", string(qualify.TargetMachine), "Where to record: machine (Platform Machine) or bmh (Metal3 BareMetalHost).")
	flag.StringVar(&cfg.LocalCluster, "local-cluster", "", "Platform name of the cluster this controller runs in, for Metal3 providers whose clusterRef names it.")
	flag.StringVar(&cfg.ClusterKubeconfigDir, "cluster-kubeconfig-dir", "", "Directory with one kubeconfig file per other Platform cluster, named after the cluster.")
	flag.StringVar(&netboxTokenFile, "netbox-token-file", "", "File holding a NetBox API token. Empty disables NetBox updates.")
	flag.StringVar(&cfg.NetBoxAdmitTag, "netbox-admit-tag", "", "NetBox tag removed from a device that fails, the tag that brings it into vCluster Platform.")
	flag.StringVar(&cfg.NetBoxQualifiedTag, "netbox-qualified-tag", "", "NetBox tag added to a device that passes.")
	flag.IntVar(&cfg.KeepReports, "keep-reports", 5, "QualificationReports to keep per machine. 0 keeps any number. The latest is always kept.")
	flag.DurationVar(&cfg.MaxReportAge, "max-report-age", 90*24*time.Hour, "Drop reports finished longer ago. 0 keeps any age. The latest is always kept.")
	flag.StringVar(&topology, "topology", qualify.DefaultTopology, "Topology names to record and label metrics with, as name=machine-label pairs.")
	flag.BoolVar(&cfg.DryRun, "dry-run", false, "Log every write instead of making it.")
	flag.StringVar(&metricsAddr, "metrics-bind-address", ":8080", "Metrics address. 0 disables.")
	flag.StringVar(&probeAddr, "health-probe-bind-address", ":8081", "Health probe address.")
	flag.BoolVar(&leaderElect, "leader-elect", false, "Enable leader election, for more than one replica.")
	opts := zap.Options{}
	opts.BindFlags(flag.CommandLine)
	flag.Parse()
	ctrl.SetLogger(zap.New(zap.UseFlagOptions(&opts)))
	log := ctrl.Log.WithName("setup")

	for _, t := range strings.Split(templates, ",") {
		if t = strings.TrimSpace(t); t != "" {
			cfg.TemplateNames = append(cfg.TemplateNames, t)
		}
	}
	cfg.Target = qualify.Target(target)
	var err error
	if cfg.Topology, err = qualify.ParseTopology(topology); err != nil {
		log.Error(err, "invalid --topology")
		os.Exit(1)
	}
	if err := cfg.Validate(); err != nil {
		log.Error(err, "invalid configuration")
		os.Exit(1)
	}
	var netbox *qualify.NetBox
	if netboxTokenFile != "" {
		b, err := os.ReadFile(netboxTokenFile)
		if err != nil {
			log.Error(err, "read NetBox token")
			os.Exit(1)
		}
		if token := strings.TrimSpace(string(b)); token != "" {
			netbox = &qualify.NetBox{Token: token}
		}
	}

	scheme := runtime.NewScheme()
	_ = clientgoscheme.AddToScheme(scheme)
	mgr, err := ctrl.NewManager(ctrl.GetConfigOrDie(), ctrl.Options{
		Scheme:                 scheme,
		Metrics:                metricsserver.Options{BindAddress: metricsAddr},
		HealthProbeBindAddress: probeAddr,
		LeaderElection:         leaderElect,
		LeaderElectionID:       "gpu-burn-in-recorder.gpu-qualification",
	})
	if err != nil {
		log.Error(err, "create manager")
		os.Exit(1)
	}
	r := &qualify.Reconciler{
		Client: mgr.GetClient(),
		Reader: mgr.GetAPIReader(),
		Clusters: &qualify.KubeconfigClusters{
			Local:    cfg.LocalCluster,
			LocalCli: mgr.GetClient(),
			Dir:      cfg.ClusterKubeconfigDir,
		},
		NetBox: netbox,
		Events: mgr.GetEventRecorderFor("gpu-burn-in-recorder"),
		Config: cfg,
	}
	if err := r.SetupWithManager(mgr); err != nil {
		log.Error(err, "set up controller")
		os.Exit(1)
	}
	ctrlmetrics.Registry.MustRegister(qualify.NewReportCollector(mgr.GetClient(), cfg.Topology))
	_ = mgr.AddHealthzCheck("healthz", healthz.Ping)
	_ = mgr.AddReadyzCheck("readyz", healthz.Ping)

	log.Info("starting", "templates", cfg.TemplateNames, "target", cfg.Target, "labelDomain", cfg.LabelDomain,
		"netbox", netbox != nil, "dryRun", cfg.DryRun)
	if err := mgr.Start(ctrl.SetupSignalHandler()); err != nil {
		log.Error(err, "manager stopped")
		os.Exit(1)
	}
}
