package k8scluster

import (
	"context"
	"net/http"
	"net/url"
	"strconv"

	"github.com/tkadauke/syrus/cli/pkg/api"
)

const clustersPath = "/api/v1/app/admin/kubernetes_clusters"

type Cluster struct {
	ID                    int64  `json:"id"`
	Label                 string `json:"label"`
	APIServerURL          string `json:"api_server_url"`
	AgenticAccessEnabled  bool   `json:"agentic_access_enabled"`
	AllowWrites           bool   `json:"allow_writes"`
	InsecureSkipTLSVerify bool   `json:"insecure_skip_tls_verify"`
	CredentialKind        string `json:"credential_kind"`
	CreatedAt             string `json:"created_at"`
	UpdatedAt             string `json:"updated_at"`
}

type ClusterList struct {
	KubernetesClusters []Cluster `json:"kubernetes_clusters"`
}

func ListClusters(ctx context.Context, c *api.Client) (ClusterList, error) {
	var out ClusterList
	err := c.Do(ctx, http.MethodGet, clustersPath, nil, &out)
	return out, err
}

type Namespace struct {
	Name      string `json:"name"`
	Status    string `json:"status"`
	CreatedAt string `json:"created_at"`
}

type NamespaceList struct {
	Available  bool        `json:"available"`
	Truncated  bool        `json:"truncated"`
	Namespaces []Namespace `json:"namespaces"`
}

func ListNamespaces(ctx context.Context, c *api.Client, clusterID string) (NamespaceList, error) {
	var out NamespaceList
	err := c.Do(ctx, http.MethodGet, clusterResourcePath(clusterID, "namespaces", nil), nil, &out)
	return out, err
}

type Pod struct {
	Name           string   `json:"name"`
	Namespace      string   `json:"namespace"`
	Status         string   `json:"status"`
	PodIP          string   `json:"pod_ip"`
	NodeName       string   `json:"node_name"`
	Ready          string   `json:"ready"`
	RestartCount   int      `json:"restart_count"`
	ContainerNames []string `json:"container_names"`
	CreatedAt      string   `json:"created_at"`
}

type PodList struct {
	Available bool  `json:"available"`
	Truncated bool  `json:"truncated"`
	Pods      []Pod `json:"pods"`
}

func ListPods(ctx context.Context, c *api.Client, clusterID string, namespace string) (PodList, error) {
	var out PodList
	err := c.Do(ctx, http.MethodGet, clusterResourcePath(clusterID, "pods", namespaceQuery(namespace)), nil, &out)
	return out, err
}

type PodLogs struct {
	Available bool   `json:"available"`
	Pod       string `json:"pod"`
	Namespace string `json:"namespace"`
	Container string `json:"container"`
	Log       string `json:"log"`
}

func GetPodLogs(ctx context.Context, c *api.Client, clusterID string, name string, namespace string, container string, tailLines int) (PodLogs, error) {
	var out PodLogs
	values := url.Values{}
	values.Set("namespace", namespace)
	if container != "" {
		values.Set("container", container)
	}
	if tailLines > 0 {
		values.Set("tail_lines", strconv.Itoa(tailLines))
	}
	path := clusterResourcePath(clusterID, "pods/"+url.PathEscape(name)+"/logs", values)
	err := c.Do(ctx, http.MethodGet, path, nil, &out)
	return out, err
}

type Deployment struct {
	Name              string `json:"name"`
	Namespace         string `json:"namespace"`
	Replicas          int    `json:"replicas"`
	ReadyReplicas     int    `json:"ready_replicas"`
	AvailableReplicas int    `json:"available_replicas"`
	UpdatedReplicas   int    `json:"updated_replicas"`
	CreatedAt         string `json:"created_at"`
}

type DeploymentList struct {
	Available   bool         `json:"available"`
	Truncated   bool         `json:"truncated"`
	Deployments []Deployment `json:"deployments"`
}

func ListDeployments(ctx context.Context, c *api.Client, clusterID string, namespace string) (DeploymentList, error) {
	var out DeploymentList
	err := c.Do(ctx, http.MethodGet, clusterResourcePath(clusterID, "deployments", namespaceQuery(namespace)), nil, &out)
	return out, err
}

type ServicePort struct {
	Name       string `json:"name"`
	Port       int    `json:"port"`
	TargetPort any    `json:"target_port"`
	Protocol   string `json:"protocol"`
}

type Service struct {
	Name        string        `json:"name"`
	Namespace   string        `json:"namespace"`
	Type        string        `json:"type"`
	ClusterIP   string        `json:"cluster_ip"`
	ExternalIPs []string      `json:"external_ips"`
	Ports       []ServicePort `json:"ports"`
	CreatedAt   string        `json:"created_at"`
}

type ServiceList struct {
	Available bool      `json:"available"`
	Truncated bool      `json:"truncated"`
	Services  []Service `json:"services"`
}

func ListServices(ctx context.Context, c *api.Client, clusterID string, namespace string) (ServiceList, error) {
	var out ServiceList
	err := c.Do(ctx, http.MethodGet, clusterResourcePath(clusterID, "services", namespaceQuery(namespace)), nil, &out)
	return out, err
}

type Node struct {
	Name              string   `json:"name"`
	Ready             bool     `json:"ready"`
	Roles             []string `json:"roles"`
	KubeletVersion    string   `json:"kubelet_version"`
	InternalIP        string   `json:"internal_ip"`
	CapacityCPU       string   `json:"capacity_cpu"`
	CapacityMemory    string   `json:"capacity_memory"`
	AllocatableCPU    string   `json:"allocatable_cpu"`
	AllocatableMemory string   `json:"allocatable_memory"`
	CreatedAt         string   `json:"created_at"`
}

type NodeList struct {
	Available bool   `json:"available"`
	Truncated bool   `json:"truncated"`
	Nodes     []Node `json:"nodes"`
}

func ListNodes(ctx context.Context, c *api.Client, clusterID string) (NodeList, error) {
	var out NodeList
	err := c.Do(ctx, http.MethodGet, clusterResourcePath(clusterID, "nodes", nil), nil, &out)
	return out, err
}

type PersistentVolumeClaim struct {
	Name         string   `json:"name"`
	Namespace    string   `json:"namespace"`
	Status       string   `json:"status"`
	Capacity     string   `json:"capacity"`
	StorageClass string   `json:"storage_class"`
	AccessModes  []string `json:"access_modes"`
	VolumeName   string   `json:"volume_name"`
	CreatedAt    string   `json:"created_at"`
}

type PersistentVolumeClaimList struct {
	Available              bool                    `json:"available"`
	Truncated              bool                    `json:"truncated"`
	PersistentVolumeClaims []PersistentVolumeClaim `json:"persistent_volume_claims"`
}

func ListPersistentVolumeClaims(ctx context.Context, c *api.Client, clusterID string, namespace string) (PersistentVolumeClaimList, error) {
	var out PersistentVolumeClaimList
	err := c.Do(ctx, http.MethodGet, clusterResourcePath(clusterID, "pvcs", namespaceQuery(namespace)), nil, &out)
	return out, err
}

type EventInvolvedObject struct {
	Kind string `json:"kind"`
	Name string `json:"name"`
}

type Event struct {
	Name           string              `json:"name"`
	Namespace      string              `json:"namespace"`
	Type           string              `json:"type"`
	Reason         string              `json:"reason"`
	Message        string              `json:"message"`
	InvolvedObject EventInvolvedObject `json:"involved_object"`
	Count          int                 `json:"count"`
	FirstTimestamp string              `json:"first_timestamp"`
	LastTimestamp  string              `json:"last_timestamp"`
}

type EventList struct {
	Available bool    `json:"available"`
	Truncated bool    `json:"truncated"`
	Events    []Event `json:"events"`
}

func ListEvents(ctx context.Context, c *api.Client, clusterID string, namespace string) (EventList, error) {
	var out EventList
	err := c.Do(ctx, http.MethodGet, clusterResourcePath(clusterID, "events", namespaceQuery(namespace)), nil, &out)
	return out, err
}

type MetricRow struct {
	Name          string `json:"name"`
	Namespace     string `json:"namespace,omitempty"`
	CPUMillicores int64  `json:"cpu_millicores"`
	MemoryBytes   int64  `json:"memory_bytes"`
}

type MetricSection struct {
	Available          bool        `json:"available"`
	Reason             string      `json:"reason"`
	Message            string      `json:"message"`
	Items              []MetricRow `json:"items"`
	TotalCPUMillicores int64       `json:"total_cpu_millicores"`
	TotalMemoryBytes   int64       `json:"total_memory_bytes"`
}

type Overview struct {
	GeneratedAt string        `json:"generated_at"`
	Nodes       MetricSection `json:"nodes"`
	Pods        MetricSection `json:"pods"`
}

func GetOverview(ctx context.Context, c *api.Client, clusterID string) (Overview, error) {
	var out Overview
	err := c.Do(ctx, http.MethodGet, clusterResourcePath(clusterID, "overview", nil), nil, &out)
	return out, err
}

func clusterResourcePath(clusterID string, resource string, values url.Values) string {
	path := clustersPath + "/" + url.PathEscape(clusterID) + "/" + resource
	if encoded := values.Encode(); encoded != "" {
		path += "?" + encoded
	}
	return path
}

func namespaceQuery(namespace string) url.Values {
	if namespace == "" {
		return nil
	}
	values := url.Values{}
	values.Set("namespace", namespace)
	return values
}
