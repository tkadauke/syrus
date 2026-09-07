// Package k8scluster is the CLI surface for the bundled k8s_cluster plugin.
//
// It is a thin, read-only client over the plugin's existing admin API
// (plugins/k8s_cluster/app/controllers/api/v1/app/admin/): registered
// clusters, then namespace/pod/deployment/service/node/PVC/event browsing,
// pod log tails, and the metrics.k8s.io overview. The plugin's scale/
// restart/delete-pod/cordon actions exist only as MCP tools with no REST
// route backing them, so this module deliberately does not expose write
// commands -- adding new Rails routes is out of scope for this CLI-only Job.
package k8scluster

import (
	"context"
	"errors"
	"fmt"
	"io"
	"strconv"
	"strings"
	"text/tabwriter"

	"github.com/spf13/cobra"
	"github.com/tkadauke/syrus/cli/pkg/api"
	"github.com/tkadauke/syrus/cli/pkg/cliplugin"
)

func NewK8sCommand() *cobra.Command {
	cmd := &cobra.Command{Use: "k8s", Short: "Inspect registered Kubernetes clusters"}
	cmd.AddCommand(
		newK8sClustersCommand(),
		newK8sNamespacesCommand(),
		newK8sPodsCommand(),
		newK8sDeploymentsCommand(),
		newK8sServicesCommand(),
		newK8sNodesCommand(),
		newK8sPVCsCommand(),
		newK8sEventsCommand(),
		newK8sLogsCommand(),
		newK8sOverviewCommand(),
	)
	return cmd
}

func newK8sClustersCommand() *cobra.Command {
	return &cobra.Command{
		Use:   "clusters",
		Short: "List registered Kubernetes clusters",
		Args:  cobra.NoArgs,
		RunE: func(cmd *cobra.Command, args []string) error {
			client, err := cliplugin.Client()
			if err != nil {
				return err
			}
			list, err := ListClusters(cmd.Context(), client)
			if err != nil {
				return err
			}
			tw := tabwriter.NewWriter(cmd.OutOrStdout(), 0, 0, 2, ' ', 0)
			fmt.Fprintln(tw, "ID\tLABEL\tAPI SERVER\tAGENTIC\tWRITES")
			for _, cluster := range list.KubernetesClusters {
				fmt.Fprintf(tw, "%d\t%s\t%s\t%s\t%s\n", cluster.ID, cluster.Label, cluster.APIServerURL, yesNo(cluster.AgenticAccessEnabled), yesNo(cluster.AllowWrites))
			}
			return tw.Flush()
		},
	}
}

func newK8sNamespacesCommand() *cobra.Command {
	var cluster string
	cmd := &cobra.Command{
		Use:   "namespaces",
		Short: "List namespaces in a cluster",
		Args:  cobra.NoArgs,
		RunE: func(cmd *cobra.Command, args []string) error {
			client, err := cliplugin.Client()
			if err != nil {
				return err
			}
			clusterID, err := resolveClusterID(cmd.Context(), client, cluster)
			if err != nil {
				return err
			}
			list, err := ListNamespaces(cmd.Context(), client, clusterID)
			if err != nil {
				return err
			}
			tw := tabwriter.NewWriter(cmd.OutOrStdout(), 0, 0, 2, ' ', 0)
			fmt.Fprintln(tw, "NAME\tSTATUS")
			for _, namespace := range list.Namespaces {
				fmt.Fprintf(tw, "%s\t%s\n", namespace.Name, valueOrDash(namespace.Status))
			}
			return tw.Flush()
		},
	}
	addClusterFlag(cmd, &cluster)
	return cmd
}

func newK8sPodsCommand() *cobra.Command {
	var cluster, namespace string
	cmd := &cobra.Command{
		Use:   "pods",
		Short: "List pods",
		Args:  cobra.NoArgs,
		RunE: func(cmd *cobra.Command, args []string) error {
			client, err := cliplugin.Client()
			if err != nil {
				return err
			}
			clusterID, err := resolveClusterID(cmd.Context(), client, cluster)
			if err != nil {
				return err
			}
			list, err := ListPods(cmd.Context(), client, clusterID, namespace)
			if err != nil {
				return err
			}
			tw := tabwriter.NewWriter(cmd.OutOrStdout(), 0, 0, 2, ' ', 0)
			fmt.Fprintln(tw, "NAME\tNAMESPACE\tSTATUS\tREADY\tRESTARTS\tNODE")
			for _, pod := range list.Pods {
				fmt.Fprintf(tw, "%s\t%s\t%s\t%s\t%d\t%s\n", pod.Name, pod.Namespace, pod.Status, pod.Ready, pod.RestartCount, valueOrDash(pod.NodeName))
			}
			return tw.Flush()
		},
	}
	addClusterFlag(cmd, &cluster)
	addNamespaceFlag(cmd, &namespace)
	return cmd
}

func newK8sDeploymentsCommand() *cobra.Command {
	var cluster, namespace string
	cmd := &cobra.Command{
		Use:   "deployments",
		Short: "List deployments",
		Args:  cobra.NoArgs,
		RunE: func(cmd *cobra.Command, args []string) error {
			client, err := cliplugin.Client()
			if err != nil {
				return err
			}
			clusterID, err := resolveClusterID(cmd.Context(), client, cluster)
			if err != nil {
				return err
			}
			list, err := ListDeployments(cmd.Context(), client, clusterID, namespace)
			if err != nil {
				return err
			}
			tw := tabwriter.NewWriter(cmd.OutOrStdout(), 0, 0, 2, ' ', 0)
			fmt.Fprintln(tw, "NAME\tNAMESPACE\tREPLICAS\tREADY\tAVAILABLE\tUPDATED")
			for _, deployment := range list.Deployments {
				fmt.Fprintf(tw, "%s\t%s\t%d\t%d\t%d\t%d\n", deployment.Name, deployment.Namespace, deployment.Replicas, deployment.ReadyReplicas, deployment.AvailableReplicas, deployment.UpdatedReplicas)
			}
			return tw.Flush()
		},
	}
	addClusterFlag(cmd, &cluster)
	addNamespaceFlag(cmd, &namespace)
	return cmd
}

func newK8sServicesCommand() *cobra.Command {
	var cluster, namespace string
	cmd := &cobra.Command{
		Use:   "services",
		Short: "List services",
		Args:  cobra.NoArgs,
		RunE: func(cmd *cobra.Command, args []string) error {
			client, err := cliplugin.Client()
			if err != nil {
				return err
			}
			clusterID, err := resolveClusterID(cmd.Context(), client, cluster)
			if err != nil {
				return err
			}
			list, err := ListServices(cmd.Context(), client, clusterID, namespace)
			if err != nil {
				return err
			}
			tw := tabwriter.NewWriter(cmd.OutOrStdout(), 0, 0, 2, ' ', 0)
			fmt.Fprintln(tw, "NAME\tNAMESPACE\tTYPE\tCLUSTER-IP\tPORTS")
			for _, service := range list.Services {
				fmt.Fprintf(tw, "%s\t%s\t%s\t%s\t%s\n", service.Name, service.Namespace, service.Type, valueOrDash(service.ClusterIP), formatPorts(service.Ports))
			}
			return tw.Flush()
		},
	}
	addClusterFlag(cmd, &cluster)
	addNamespaceFlag(cmd, &namespace)
	return cmd
}

func newK8sNodesCommand() *cobra.Command {
	var cluster string
	cmd := &cobra.Command{
		Use:   "nodes",
		Short: "List cluster nodes",
		Args:  cobra.NoArgs,
		RunE: func(cmd *cobra.Command, args []string) error {
			client, err := cliplugin.Client()
			if err != nil {
				return err
			}
			clusterID, err := resolveClusterID(cmd.Context(), client, cluster)
			if err != nil {
				return err
			}
			list, err := ListNodes(cmd.Context(), client, clusterID)
			if err != nil {
				return err
			}
			tw := tabwriter.NewWriter(cmd.OutOrStdout(), 0, 0, 2, ' ', 0)
			fmt.Fprintln(tw, "NAME\tREADY\tROLES\tVERSION\tINTERNAL-IP")
			for _, node := range list.Nodes {
				fmt.Fprintf(tw, "%s\t%s\t%s\t%s\t%s\n", node.Name, yesNo(node.Ready), strings.Join(node.Roles, ","), valueOrDash(node.KubeletVersion), valueOrDash(node.InternalIP))
			}
			return tw.Flush()
		},
	}
	addClusterFlag(cmd, &cluster)
	return cmd
}

func newK8sPVCsCommand() *cobra.Command {
	var cluster, namespace string
	cmd := &cobra.Command{
		Use:   "pvcs",
		Short: "List persistent volume claims",
		Args:  cobra.NoArgs,
		RunE: func(cmd *cobra.Command, args []string) error {
			client, err := cliplugin.Client()
			if err != nil {
				return err
			}
			clusterID, err := resolveClusterID(cmd.Context(), client, cluster)
			if err != nil {
				return err
			}
			list, err := ListPersistentVolumeClaims(cmd.Context(), client, clusterID, namespace)
			if err != nil {
				return err
			}
			tw := tabwriter.NewWriter(cmd.OutOrStdout(), 0, 0, 2, ' ', 0)
			fmt.Fprintln(tw, "NAME\tNAMESPACE\tSTATUS\tCAPACITY\tSTORAGE CLASS")
			for _, pvc := range list.PersistentVolumeClaims {
				fmt.Fprintf(tw, "%s\t%s\t%s\t%s\t%s\n", pvc.Name, pvc.Namespace, pvc.Status, valueOrDash(pvc.Capacity), valueOrDash(pvc.StorageClass))
			}
			return tw.Flush()
		},
	}
	addClusterFlag(cmd, &cluster)
	addNamespaceFlag(cmd, &namespace)
	return cmd
}

func newK8sEventsCommand() *cobra.Command {
	var cluster, namespace string
	cmd := &cobra.Command{
		Use:   "events",
		Short: "List recent cluster events",
		Args:  cobra.NoArgs,
		RunE: func(cmd *cobra.Command, args []string) error {
			client, err := cliplugin.Client()
			if err != nil {
				return err
			}
			clusterID, err := resolveClusterID(cmd.Context(), client, cluster)
			if err != nil {
				return err
			}
			list, err := ListEvents(cmd.Context(), client, clusterID, namespace)
			if err != nil {
				return err
			}
			tw := tabwriter.NewWriter(cmd.OutOrStdout(), 0, 0, 2, ' ', 0)
			fmt.Fprintln(tw, "NAMESPACE\tTYPE\tREASON\tOBJECT\tMESSAGE")
			for _, event := range list.Events {
				object := strings.TrimSpace(event.InvolvedObject.Kind + "/" + event.InvolvedObject.Name)
				fmt.Fprintf(tw, "%s\t%s\t%s\t%s\t%s\n", event.Namespace, event.Type, event.Reason, valueOrDash(object), event.Message)
			}
			return tw.Flush()
		},
	}
	addClusterFlag(cmd, &cluster)
	addNamespaceFlag(cmd, &namespace)
	return cmd
}

func newK8sLogsCommand() *cobra.Command {
	var cluster, namespace, container string
	var tail int
	cmd := &cobra.Command{
		Use:   "logs POD",
		Short: "Show a pod's log tail",
		Args:  cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			if strings.TrimSpace(namespace) == "" {
				return errors.New("--namespace is required")
			}
			client, err := cliplugin.Client()
			if err != nil {
				return err
			}
			clusterID, err := resolveClusterID(cmd.Context(), client, cluster)
			if err != nil {
				return err
			}
			logs, err := GetPodLogs(cmd.Context(), client, clusterID, args[0], namespace, container, tail)
			if err != nil {
				return err
			}
			fmt.Fprint(cmd.OutOrStdout(), logs.Log)
			return nil
		},
	}
	addClusterFlag(cmd, &cluster)
	cmd.Flags().StringVar(&namespace, "namespace", "", "namespace containing the pod (required)")
	cmd.Flags().StringVar(&container, "container", "", "container name (required once the pod has more than one container)")
	cmd.Flags().IntVar(&tail, "tail", 200, "number of trailing log lines")
	return cmd
}

func newK8sOverviewCommand() *cobra.Command {
	var cluster string
	cmd := &cobra.Command{
		Use:   "overview",
		Short: "Show aggregate node/pod CPU and memory usage",
		Args:  cobra.NoArgs,
		RunE: func(cmd *cobra.Command, args []string) error {
			client, err := cliplugin.Client()
			if err != nil {
				return err
			}
			clusterID, err := resolveClusterID(cmd.Context(), client, cluster)
			if err != nil {
				return err
			}
			overview, err := GetOverview(cmd.Context(), client, clusterID)
			if err != nil {
				return err
			}
			out := cmd.OutOrStdout()
			printMetricSection(out, "Nodes", overview.Nodes)
			printMetricSection(out, "Pods", overview.Pods)
			return nil
		},
	}
	addClusterFlag(cmd, &cluster)
	return cmd
}

func addClusterFlag(cmd *cobra.Command, cluster *string) {
	cmd.Flags().StringVar(cluster, "cluster", "", "cluster ID (required when more than one cluster is registered)")
}

func addNamespaceFlag(cmd *cobra.Command, namespace *string) {
	cmd.Flags().StringVar(namespace, "namespace", "", "restrict to one namespace (default: all namespaces)")
}

// resolveClusterID mirrors schedule.go's current-repository detection: when
// the caller did not pin a cluster and exactly one is registered, use it;
// otherwise ask for --cluster rather than guessing.
func resolveClusterID(ctx context.Context, client *api.Client, flag string) (string, error) {
	if trimmed := strings.TrimSpace(flag); trimmed != "" {
		return trimmed, nil
	}
	list, err := ListClusters(ctx, client)
	if err != nil {
		return "", err
	}
	switch len(list.KubernetesClusters) {
	case 0:
		return "", errors.New("no Kubernetes clusters are registered")
	case 1:
		return strconv.FormatInt(list.KubernetesClusters[0].ID, 10), nil
	default:
		return "", errors.New("multiple clusters are registered; pass --cluster ID (see `syrus k8s clusters`)")
	}
}

func printMetricSection(out io.Writer, label string, section MetricSection) {
	if !section.Available {
		fmt.Fprintf(out, "%s: unavailable (%s)\n", label, valueOrDash(section.Message))
		return
	}
	fmt.Fprintf(out, "%s: %d millicores, %s across %d item(s)\n", label, section.TotalCPUMillicores, formatBytes(section.TotalMemoryBytes), len(section.Items))
}

func formatBytes(bytes int64) string {
	const unit = 1024
	if bytes < unit {
		return fmt.Sprintf("%dB", bytes)
	}
	div, exp := int64(unit), 0
	for n := bytes / unit; n >= unit; n /= unit {
		div *= unit
		exp++
	}
	return fmt.Sprintf("%.1f%ciB", float64(bytes)/float64(div), "KMGTPE"[exp])
}

func formatPorts(ports []ServicePort) string {
	if len(ports) == 0 {
		return "-"
	}
	parts := make([]string, 0, len(ports))
	for _, port := range ports {
		parts = append(parts, fmt.Sprintf("%d/%s", port.Port, valueOrDash(port.Protocol)))
	}
	return strings.Join(parts, ",")
}

func yesNo(value bool) string {
	if value {
		return "yes"
	}
	return "no"
}

func valueOrDash(value string) string {
	if strings.TrimSpace(value) == "" {
		return "-"
	}
	return value
}
