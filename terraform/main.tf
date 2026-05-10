terraform {
  required_version = ">= 1.0"

  required_providers {
    kind = {
      source  = "tehcyx/kind"
      version = "~> 0.6"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.14"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.2"
    }
  }
}

# ── Locals ────────────────────────────────────────────────────────────────────

locals {
  cluster_name  = "ha-cluster"
  context       = "kind-ha-cluster"
  manifests_dir = path.module
}

# ── Kind cluster ──────────────────────────────────────────────────────────────

resource "kind_cluster" "ha" {
  name = local.cluster_name

  kind_config {
    kind        = "Cluster"
    api_version = "kind.x-k8s.io/v1alpha4"

    # Control plane 1 — carries ingress port mappings and ingress-ready label
    node {
      role = "control-plane"

      kubeadm_config_patches = [
        <<-PATCH
        kind: InitConfiguration
        nodeRegistration:
          kubeletExtraArgs:
            node-labels: "ingress-ready=true"
        PATCH
      ]

      extra_port_mappings {
        container_port = 80
        host_port      = 80
        protocol       = "TCP"
      }

      extra_port_mappings {
        container_port = 443
        host_port      = 443
        protocol       = "TCP"
      }
    }

    # Control planes 2 & 3 — stacked HA (etcd co-located)
    node { role = "control-plane" }
    node { role = "control-plane" }

    # Workers
    node { role = "worker" }
    node { role = "worker" }
  }
}

# ── Providers configured from cluster output ───────────────────────────────────

provider "helm" {
  kubernetes {
    host                   = kind_cluster.ha.endpoint
    cluster_ca_certificate = kind_cluster.ha.cluster_ca_certificate
    client_certificate     = kind_cluster.ha.client_certificate
    client_key             = kind_cluster.ha.client_key
  }
}

# ── NGINX Ingress Controller ──────────────────────────────────────────────────
#
# Helm chart configured for kind:
#   - hostPort enabled so port 80/443 bind on the host via the extraPortMappings
#   - nodeSelector targets the ingress-ready control-plane node
#   - tolerations allow scheduling on the control-plane taint
#   - service type NodePort (required alongside hostPort on kind)

resource "helm_release" "ingress_nginx" {
  name             = "ingress-nginx"
  repository       = "https://kubernetes.github.io/ingress-nginx"
  chart            = "ingress-nginx"
  namespace        = "ingress-nginx"
  create_namespace = true
  wait             = true
  timeout          = 120

  values = [
    <<-YAML
    controller:
      hostPort:
        enabled: true
      service:
        type: NodePort
      nodeSelector:
        ingress-ready: "true"
      tolerations:
        - key: node-role.kubernetes.io/control-plane
          operator: Exists
          effect: NoSchedule
      updateStrategy:
        type: RollingUpdate
        rollingUpdate:
          maxUnavailable: 1
    YAML
  ]

  depends_on = [kind_cluster.ha]
}

# ── Apps ──────────────────────────────────────────────────────────────────────
#
# Each app is a ConfigMap (Python server + HTML), Deployment, Service, and
# Ingress defined in the existing manifests under 03-installation-and-setup/.
#
# null_resource + local-exec is used here so we can reuse the existing YAML
# files directly rather than duplicating the embedded HTML content in HCL.
# destroy-time provisioners clean up each app on `terraform destroy`.

resource "null_resource" "jwst_app" {
  triggers = {
    manifest = filesha256("${local.manifests_dir}/jwst-app.yaml")
  }

  provisioner "local-exec" {
    command = "kubectl apply -f ${local.manifests_dir}/jwst-app.yaml --context ${local.context}"
  }

  provisioner "local-exec" {
    when    = destroy
    command = "kubectl delete -f ${self.triggers.manifest} --context kind-ha-cluster --ignore-not-found"
  }

  depends_on = [helm_release.ingress_nginx]
}

resource "null_resource" "cube_app" {
  triggers = {
    manifest = filesha256("${local.manifests_dir}/cube-app.yaml")
  }

  provisioner "local-exec" {
    command = "kubectl apply -f ${local.manifests_dir}/cube-app.yaml --context ${local.context}"
  }

  provisioner "local-exec" {
    when    = destroy
    command = "kubectl delete -f ${self.triggers.manifest} --context kind-ha-cluster --ignore-not-found"
  }

  depends_on = [helm_release.ingress_nginx]
}

resource "null_resource" "galaga_app" {
  triggers = {
    manifest = filesha256("${local.manifests_dir}/galaga-app.yaml")
  }

  provisioner "local-exec" {
    command = "kubectl apply -f ${local.manifests_dir}/galaga-app.yaml --context ${local.context}"
  }

  provisioner "local-exec" {
    when    = destroy
    command = "kubectl delete -f ${self.triggers.manifest} --context kind-ha-cluster --ignore-not-found"
  }

  depends_on = [helm_release.ingress_nginx]
}

# ── Outputs ───────────────────────────────────────────────────────────────────

output "cluster_name" {
  value = kind_cluster.ha.name
}

output "endpoints" {
  value = {
    jwst   = "http://localhost"
    cube   = "http://localhost/cube"
    galaga = "http://localhost/galaga"
  }
}
