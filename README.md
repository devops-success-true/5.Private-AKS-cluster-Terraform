

# Create a private Azure Kubernetes Service cluster using Terraform and Github Actions #

This repo shows how to create a private AKS cluster, all project's infrastructure, prepare the AKS (k8s) cluster with necessary addons and manage the application using:

- Terraform as infrastructure as code (IaC) tool to build, change, and version the infrastructure on Azure in a safe, repeatable, and efficient way.
- Github Actions Pipeline to automate the deployment and undeployment of the entire infrastructure on multiple environments on the Azure platform.
- Helm charts to manage Kubernetes add-ons (ArgoCD, Ingress-NGINX, Cert-Manager, Prometheus, Grafana, Loki) and custom application deployments.
- kubectl for one-off operations, debugging, and applying CRDs or manifests not managed through Helm/Terraform.

In a private AKS cluster, the API server endpoint is not exposed via a public IP address. Hence, to manage the API server, you will need to use a virtual machine that has access to the AKS cluster's Azure Virtual Network (VNet). This sample repo deploys a jumpbox virtual machine in the hub virtual network peered with the virtual network that hosts the private AKS cluster. There are several options for establishing network connectivity to the private cluster.

- Create a virtual machine in the same Azure Virtual Network (VNet) as the AKS cluster.
- Use a virtual machine in a separate network and set up Virtual network peering. See the section below for more information on this option.
- Use an Express Route or VPN connection.

Creating a virtual machine in the same virtual network as the AKS cluster or in a peered virtual network is the easiest option. Express Route and VPNs add costs and require additional networking complexity. Virtual network peering requires you to plan your network CIDR ranges to ensure there are no overlapping ranges. For more information, see [Create a private Azure Kubernetes Service cluster](https://docs.microsoft.com/en-us/azure/aks/private-clusters). For more information on Azure Private Links, see [What is Azure Private Link?](https://docs.microsoft.com/en-us/azure/private-link/private-link-overview)

In addition, this repo creates private endpoints to access all the managed services deployed by the Terraform modules via their private IP addresses: 

- Azure Container Registry
- Azure Storage Account
- Azure Key Vault

## Architecture ##

The following picture shows the high-level architecture created by the Terraform modules included in this repo:

![Architecture](images/normalized-architecture.png)

The following picture provides a more detailed view of the infrastructure on Azure.

![Architecture](images/overall-architecture.png)

The architecture is composed of the following elements:

- A hub virtual network with three subnets:
  - AzureBastionSubnet used by Azure Bastion
  - AzureFirewallSubnet used by Azure Firewall
- A new virtual network with three subnets:
  - SystemSubnet used by the AKS system node pool
  - UserSubnet used by the AKS user node pool
  - VmSubnet used by the jumpbox virtual machine and private endpoints
- The private AKS cluster uses a user-defined managed identity to create additional resources like load balancers and managed disks in Azure.
- The private AKS cluster is composed of a:
  - System node pool hosting only critical system pods and services. The worker nodes have node taint which prevents application pods from beings scheduled on this node pool.
  - User node pool hosting user workloads and artifacts.
- An Azure Firewall used to control the egress traffic from the private AKS cluster. For more information on how to lock down your private AKS cluster and filter outbound traffic, see: 
  - [Control egress traffic for cluster nodes in Azure Kubernetes Service (AKS)](https://docs.microsoft.com/en-us/azure/aks/limit-egress-traffic)
  - [Use Azure Firewall to protect Azure Kubernetes Service (AKS) Deployments](https://docs.microsoft.com/en-us/azure/firewall/protect-azure-kubernetes-service)
- An AKS cluster with a private endpoint to the API server. The cluster can communicate with the API server exposed via a Private Link Service using a private endpoint.
- An Azure Bastion resource that provides secure and seamless SSH connectivity to the VM virtual machine directly in the Azure portal over SSL.
- An Azure Container Registry (ACR) to build, store, and manage container images and artifacts in a private registry for all types of container deployments.
- When the ACR SKU is equal to Premium, a Private Endpoint is created to allow the private AKS cluster to access ACR via a private IP address. For more information, see [Connect privately to an Azure container registry using Azure Private Link](https://docs.microsoft.com/en-us/azure/container-registry/container-registry-private-link).
- A jumpbox virtual machine used to manage the Azure Kubernetes Cluster.
- A Private DNS Zone for the name resolution of each private endpoint.
- A Virtual Network Link between each Private DNS Zone and both the hub and spoke virtual networks.
- A Log Analytics workspace to collect the diagnostics logs and metrics of both the AKS cluster and Vm virtual machine.
- Monitoring Add-ons (Helm) – Prometheus and Grafana are deployed via Helm for metrics collection, alerting, and visualization.
- Security Add-ons (Helm) – cert-manager and certificate issuers are deployed to automate TLS certificate provisioning and renewal for Kubernetes workloads.
- Continuous Delivery (Helm) – Argo CD is deployed for GitOps-based application delivery, continuously reconciling the cluster state with this repository.
- Ingress (Helm) – NGINX Ingress Controller is deployed via Helm to securely expose cluster applications with path-based routing and SSL termination.
- kubectl-applied Resources – certain add-on components and CRDs are deployed using kubectl apply when Helm is not suitable (e.g., custom manifests, RBAC).
- Application Workloads (Helm) – workloads are packaged as Helm charts and templates for deployments, services, ConfigMaps, Secrets, and ingress rules. Values are managed via values.yaml for environment-specific configuration.

## Limitations ##

A private AKS cluster has the following limitations:

- No IP allowlisting → API server IP ranges apply only to public endpoints, not private ones.
- Azure Private Link constraints → Standard Private Link limitations apply.
- ACR integration → If you use ACR with private endpoints, the registry VNet must be accessible (via peering or same VNet).
- No conversion → You cannot convert an existing public AKS cluster into a private cluster.
- Private endpoint dependency → Deleting or modifying the AKS private endpoint breaks API connectivity.

## Requirements

Before deploying Terraform modules using **GitHub Actions**, make sure you complete the following prerequisites:

1. **Remote Terraform state backend**  
   Store the Terraform state file in an Azure Storage Account for state persistence, state locking, and encryption at rest.  
   👉 See: [Store Terraform state in Azure Storage](https://learn.microsoft.com/en-us/azure/developer/terraform/store-state-in-azure-storage)

2. **GitHub repository**  
   Ensure your infrastructure code is pushed to a GitHub repository. GitHub Actions workflows will run from this repo.

3. **OIDC-based authentication with Azure** (recommended best practice)  
   - Register a new **Azure AD App Registration** for GitHub Actions.  
   - Configure a **Federated Identity Credential** that links your GitHub repository (`repo:ORG/REPO:ref:refs/heads/main`) with Azure AD.  
   - Grant the App Registration the necessary **roles** (e.g., `Owner` or `Contributor` on the subscription or resource group).  

   > With OIDC, you don’t need to store client secrets in GitHub. Authentication is secure, short-lived tokens are exchanged automatically, and security risks are minimized.

## Fix the routing issue ##

When you deploy an Azure Firewall into a hub virtual network and your private AKS cluster in a spoke virtual network, and you want to use the Azure Firewall to control the egress traffic using network and application rule collections, you need to make sure to properly configure the ingress traffic to any public endpoint exposed by any service running on AKS to enter the system via one of the public IP addresses used by the Azure Firewall. In order to route the traffic of your AKS workloads to the Azure Firewall in the hub virtual network, you need to create and associate a route table to each subnet hosting the worker nodes of your cluster and create a user-defined route to forward the traffic for `0.0.0.0/0` CIDR to the private IP address of the Azure firewall and specify `Virtual appliance` as `next hop type`. For more information, see [Tutorial: Deploy and configure Azure Firewall using the Azure portal](https://docs.microsoft.com/en-us/azure/firewall/tutorial-firewall-deploy-portal#create-a-default-route).

When you introduce an Azure firewall to control the egress traffic from your private AKS cluster, you need to configure the internet traffic to go throught one of the public Ip address associated to the Azure Firewall in front of the Public Standard Load Balancer used by your AKS cluster. This is where the problem occurs. Packets arrive on the firewall's public IP address, but return to the firewall via the private IP address (using the default route). To avoid this problem, create an additional user-defined route for the firewall's public IP address as shown in the picture below. Packets going to the firewall's public IP address are routed via the Internet. This avoids taking the default route to the firewall's private IP address.

![Firewall](images/firewall-lb-asymmetric.png)

For more information, see:

- [Restrict egress traffic from an AKS cluster using Azure firewall](https://docs.microsoft.com/en-us/azure/aks/limit-egress-traffic#restrict-egress-traffic-using-azure-firewall)
- [Integrate Azure Firewall with Azure Standard Load Balancer](https://docs.microsoft.com/en-us/azure/firewall/integrate-lb)

## Terraform State

Terraform stores [state](https://www.terraform.io/docs/language/state/index.html) about your managed infrastructure and configuration in a special file called the **state file**. This state is used by Terraform to:

- Map real-world resources to your configuration.
- Track metadata (like resource dependencies).
- Improve performance when managing large infrastructures.
- Reconcile deployed resources with your Terraform code (determine what to add, update, or delete).

By default, Terraform state is stored locally in a file called `terraform.tfstate`. However, storing state locally is **not recommended** in production because:

- It doesn’t work well in team environments (no state sharing or locking).
- State files can include sensitive information (secrets, connection strings).
- Storing state locally increases the risk of corruption or accidental deletion.

### Remote State in Azure

The best practice is to use a **remote backend**. Terraform provides an [Azure backend](https://www.terraform.io/docs/language/settings/backends/azurerm.html) that stores the state as a **Blob** inside an Azure Storage Account.  

Benefits of using the Azure backend:
- State is persisted and shared across teams.
- Supports state locking and consistency checks.
- Secured with encryption at rest and RBAC permissions.

### GitHub Actions & Remote State

In this repository, Terraform is executed via **GitHub Actions** (not Azure DevOps).  
To follow best practices:

1. **Create an Azure Storage Account + Blob Container** to hold your Terraform state.
2. Configure the Terraform backend in your `main.tf` (or a dedicated `backend.tf`) like this:

   ```hcl
   terraform {
     backend "azurerm" {
       resource_group_name  = "rg-terraform-backend"
       storage_account_name = "tfstateaccount"
       container_name       = "tfstate"
       key                  = "infrastructure.tfstate"
     }
   }

Replace tfstateaccount, tfstate, and infrastructure.tfstate with your actual names. To clarify, I initially created manually this storage account before running Github Actions pipeline. 

Then my OIDC federated identity (enterprise app in AAD) needs Contributor or Storage Blob Data Contributor role assignments at least on the storage account (or RG level), the OIDC- Storage Account access.

Run once:
```bash
# Allow my GitHub OIDC identity to write state into the storage account tfstateaccount
az role assignment create \
  --assignee <OIDC_CLIENT_ID_OR_OBJECT_ID> \
  --role "Storage Blob Data Contributor" \
  --scope /subscriptions/<SUBSCRIPTION_ID>/resourceGroups/rg-terraform-backend/providers/Microsoft.Storage/storageAccounts/tfstateaccount
``` 

The [Azure Provider](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs) or **azurerm** can be used to configure infrastructure in Microsoft Azure using the Azure Resource Manager API's. Terraform provides a [backend](https://www.terraform.io/docs/language/settings/backends/azurerm.html) for the Azure Provider that allows to store the state as a Blob with the given Key within a given Blob Container inside a Blob Storage Account. This backend also supports state locking and consistency checking via native capabilities of the Azure Blob Storage. [](https://www.terraform.io/docs/language/settings/backends/azurerm.html) When using Github Actions to deploy services to a cloud environment, you should use this backend to store the state to a remote storage account. For more information on how to create to use a storage account to store remote Terraform state, state locking, and encryption at rest, see [Store Terraform state in Azure Storage](https://docs.microsoft.com/en-us/azure/developer/terraform/store-state-in-azure-storage?tabs=azure-cli). Under the [storage-account](./storage-account) folder in this sample, you can find a Terraform module and bash script to deploy an Azure storage account where you can persist the Terraform state as a blob.

## GitHub Actions Runners for Private AKS Clusters

Since this project uses **GitHub Actions** (instead of Azure DevOps), we rely on GitHub-hosted runners with **OIDC authentication** to securely access Azure.  

> ⚠️ Note: GitHub-hosted runners are ephemeral and live outside your Azure VNet. If you deploy a **private AKS cluster**, you need network access to the cluster API server. Common approaches include:
>
> - Using an **Azure Bastion / Jumpbox VM** inside the same VNet (already provisioned in this repo) to run `kubectl` commands.
> - Setting up a **self-hosted GitHub Actions runner** inside your VNet or in a peered VNet, so it has private network access to AKS.
> - Using ArgoCD (already part of this repo) to manage workloads, so your CI/CD pipelines don’t need direct `kubectl` connectivity.

In most cases, the **best practice** is:
- Keep infrastructure deployments (Terraform, AKS, add-ons) in GitHub Actions with OIDC + AzureRM provider.
- Use **ArgoCD GitOps** for all Kubernetes workloads (apps, manifests, Helm), so the runners never need private API access.

## Secrets and Variables

Instead of Azure DevOps Variable Groups, this repo uses:
- **GitHub Secrets** → to store sensitive values (DockerHub creds, Azure Subscription IDs, OIDC client IDs, etc.).
- **GitHub Environments / Variables** → to store non-sensitive configuration like SonarCloud project keys or app base URLs.

All secrets/variables are consumed directly in the GitHub Actions workflows under `.github/workflows/`.

## GitHub Actions Workflows ##

This project uses **GitHub Actions** instead of Azure DevOps pipelines.  
The automation is split across **two repositories**, following GitOps best practices:

- **App Repository** (`4.Github-Actions-CI-CD-pipeline-docker-images-MERN-app-e-Commerce`)  
  Contains the MERN application source code and a CI pipeline.  
  The pipeline:
  1. Runs quality checks (lint, Prettier, SonarCloud, Trivy).
  2. Builds and pushes frontend + backend Docker images to Docker Hub.
  3. Updates the image tags in the `values.yaml` file inside this repo (`5.Private-AKS-cluster-Terraform`).

- **Infrastructure Repository** (`5.Private-AKS-cluster-Terraform`)  
  Contains:
  - Terraform code to provision Azure infrastructure (RGs, VNets, Firewall, AKS, ACR, Bastion, Key Vault, Private Endpoints, etc.).
  - Addons for the AKS cluster (ArgoCD, Prometheus, Grafana, Cert-Manager, Ingress NGINX, etc.).
  - Helm charts/manifests for application deployment.  
  ArgoCD (running in AKS) continuously watches this repo and applies changes automatically.

---

### Key Concepts

- A **trigger** (e.g., `push` to main, or `workflow_dispatch`) starts a workflow run.
- A **workflow** consists of one or more **jobs**.
- Each **job** runs on a **runner** (GitHub-hosted or self-hosted).
- A job contains one or more **steps**.
- A **step** can run a shell script or use a pre-built GitHub **action**.
- **Artifacts** (e.g., Terraform plans, build outputs) can be uploaded and shared between jobs.

For more information:
- [What is GitHub Actions?](https://docs.github.com/en/actions/learn-github-actions/understanding-github-actions)
- [Events that trigger workflows](https://docs.github.com/en/actions/using-workflows/events-that-trigger-workflows)
- [About jobs](https://docs.github.com/en/actions/using-jobs/using-jobs-in-a-workflow)

---

### Workflows in This Setup

This setup uses two main workflows across the repos:

| Repository | Workflow Name | Description |
| :--- | :--- | :--- |
| `5.Private-AKS-cluster-Terraform` | [infra-deploy.yml](.github/workflows/infra-deploy.yml) | Provisions all Azure infra with Terraform and deploys AKS addons. Uses OIDC authentication with Azure. |
| `4.Github-Actions-CI-CD-pipeline-docker-images-MERN-app-e-Commerce` | [ci-cd.yml](.github/workflows/ci-cd.yml) | Builds & pushes MERN Docker images, then commits new image tags into the Helm `values.yaml` file in the infra repo. ArgoCD syncs workloads in AKS automatically. |

---

### Terraform in GitHub Actions

Instead of the Azure DevOps Terraform extension, we use the official [hashicorp/setup-terraform](https://github.com/hashicorp/setup-terraform) GitHub Action.  
The infra workflow includes the standard Terraform commands:

- [`init`](https://developer.hashicorp.com/terraform/cli/commands/init) – initialize provider plugins and backend
- [`validate`](https://developer.hashicorp.com/terraform/cli/commands/validate) – check configuration syntax
- [`plan`](https://developer.hashicorp.com/terraform/cli/commands/plan) – preview infrastructure changes
- [`apply`](https://developer.hashicorp.com/terraform/cli/commands/apply) – deploy infrastructure changes
- [`destroy`](https://developer.hashicorp.com/terraform/cli/commands/destroy) – remove all provisioned infrastructure

Terraform state is stored remotely in an Azure Storage Account, configured as a Terraform backend.

---

# Examples of Usage / Deployment

After setting up the infrastructure and add-ons for the AKS cluster via the GitHub Actions pipeline with Terraform, the next step is to deploy the application and additional cluster resources.
This repository includes both Helm-based deployments (for the MERN application) and raw Kubernetes manifests (for cluster add-ons and integrations).

Below are example commands for deploying each component.  

---

## 1. Deploy MERN App (Helm)

The MERN application is packaged as a Helm chart under `helm/mern`.

```bash
# Navigate to the chart directory
cd helm/mern

# Install the MERN app (replace <release-name> and <namespace> as needed)
helm install <release-name> . -n <namespace> --create-namespace

# Example:
helm install mern-app . -n mern --create-namespace

# Upgrade after making changes
helm upgrade mern-app . -n mern
```

---

## 2. Deploy ArgoCD

Manifests are under `k8s/argocd`.

```bash
kubectl apply -f k8s/argocd/ -n argocd --create-namespace
```

---

## 3. Deploy Cert-Manager + ClusterIssuer

Manifests are under `k8s/cert-manager`.

```bash
kubectl apply -f k8s/cert-manager/ -n cert-manager --create-namespace
```

---

## 4. Deploy Ingress Rules

Manifests are under `k8s/ingress`.

```bash
kubectl apply -f k8s/ingress/ -n mern
```

---

## 5. Deploy Monitoring (Prometheus, Grafana, Loki, etc.)

Manifests are under `k8s/monitoring`.

```bash
kubectl apply -f k8s/monitoring/ -n monitoring --create-namespace
```

---

## 6. Deploy Storage Account CSI Resources

Manifests are under `k8s/storage-account`.

```bash
kubectl apply -f k8s/storage-account/ -n mern
```

---

## Notes

- All commands assume I already configured access to my **private AKS cluster** (via Bastion/jumpbox or a self-hosted GitHub runner).  
- Adjust namespaces if needed (`mern`, `argocd`, `cert-manager`, `monitoring`).  
- For Helm charts, prefer `helm upgrade --install` for idempotent deployments:
- The YAML manifests under `k8s/storage/` (StorageClasses and PVCs) are **not applied in this repository**, since they are not referenced in the `helm/mern` deployments. They are included here only as examples of configuration, to demonstrate how persistent storage could be defined if required. In future repositories that focus specifically on **Kubernetes application management and orchestration features**, these storage resources (StorageClasses, PVCs, etc.) will be fully implemented and referenced by the workloads.

---

## Cleanup

To remove resources when no longer needed:

```bash
# Uninstall MERN Helm release
helm uninstall mern-app -n mern

# Delete Kubernetes manifests
kubectl delete -f k8s/argocd/ -n argocd
kubectl delete -f k8s/cert-manager/ -n cert-manager
kubectl delete -f k8s/ingress/ -n mern
kubectl delete -f k8s/monitoring/ -n monitoring
kubectl delete -f k8s/storage-account/ -n mern
```


## Azure Firewall in front of the Internal Standard Load Balancer of the AKS cluster ##

In this setup, the AKS cluster is deployed in **private mode**, and inbound/outbound traffic is routed through **Azure Firewall**. Applications are exposed using an [NGINX ingress controller](https://kubernetes.github.io/ingress-nginx/) deployed via Terraform.  
The ingress controller is fronted by an **internal Standard Load Balancer** with a private IP in the AKS virtual network.  

For more info on how this works in AKS, see [Internal Load Balancer for AKS](https://learn.microsoft.com/azure/aks/internal-lb).  

When you deploy an NGINX ingress controller or more in general a `LoadBalancer` or `ClusterIP` service with the `service.beta.kubernetes.io/azure-load-balancer-internal: "true"` annotation in the metadata section, an internal standard load balancer called `kubernetes-internal` gets created under the node resource group. For more information, see [Use an internal load balancer with Azure Kubernetes Service (AKS)](https://docs.microsoft.com/en-us/azure/aks/internal-lb).

Terraform modules use the [`lifecycle.ignore_changes`](https://developer.hashicorp.com/terraform/language/meta-arguments/lifecycle#ignore_changes) argument for Firewall Policies and Route Tables to avoid Terraform overwriting rule changes made operationally (for example, DNAT or UDR updates).

![Internal Standard Load Balancer](images/firewall-internal-load-balacer.png)

### Message Flow

1. A request for the AKS-hosted application arrives at a **public IP exposed by Azure Firewall**.  
2. An **Azure Firewall DNAT rule** translates this public IP/port to the internal IP/port of the **AKS Standard Load Balancer**.  
3. The AKS Internal Standard Load Balancer forwards the request to the NGINX Ingress Controller service. The Ingress Controller applies routing rules and sends traffic to the correct Kubernetes Service (frontend or backend), which then routes it to the pods.  
4. Responses travel back through the Azure Firewall using **User Defined Routes (UDRs)**.  
5. Outbound calls from workloads are also routed through the Firewall by default (`0.0.0.0/0` UDR → Virtual Appliance = Firewall private IP).  

### GitHub Actions + ArgoCD workflow

This project does use:

- **GitHub Actions** provisions infrastructure (Terraform) and deploys required addons (Ingress, Cert-Manager, Prometheus, Grafana, ArgoCD, etc.).  
- Application CI/CD runs in a **separate repository**. Docker images are built and pushed to Docker Hub, and Helm `values.yaml` in this repo is updated with new image tags.  
- **ArgoCD**, running in the AKS cluster, continuously monitors this repo and syncs changes. Whenever image tags or manifests are updated, workloads in AKS are reconciled automatically.

This GitOps approach replaces the need for DevOps agents running inside the VNet. Firewall and routing still protect and control access, while GitHub Actions + ArgoCD manage deployments securely and continuously.

## API Gateway ##

In production, our AKS cluster is private and sits behind **Azure Firewall** for traffic inspection and outbound control. While the firewall handles DNAT, UDRs, and threat-intelligence filtering, it is a best practice to also use an **API Gateway** or **Ingress Controller** to securely expose web applications and REST APIs.

![API Gateway](images/api-gateway.png)

### Why use an API Gateway?
Without an API Gateway, client applications would connect directly to Kubernetes services. This creates several issues:

- **Coupling**: client applications depend directly on internal microservices. Refactoring or restructuring services risks breaking clients. An API Gateway introduces an abstraction layer.  
- **Chattiness**: retrieving data from multiple microservices often means many client requests. A gateway can aggregate these.  
- **Security**: exposing all services directly increases the attack surface. A gateway centralizes ingress, SSL termination, and authentication.  
- **Cross-cutting concerns**: features like rate limiting, caching, JWT validation, and logging are handled once at the gateway, not duplicated across services.

### Options for AKS

In this repo, the following approaches are relevant:

- **Ingress Controller (most common)**  
  We deploy [NGINX Ingress Controller](https://kubernetes.github.io/ingress-nginx/) with **Cert-Manager** for TLS. This is the simplest and most common way to route traffic to workloads inside AKS.  

- **Azure Application Gateway (AGIC)**  
  For enterprises needing WAF, SSL offload, or direct Azure integration, you can use [Application Gateway Ingress Controller (AGIC)](https://learn.microsoft.com/azure/application-gateway/ingress-controller-overview).  

- **Azure Front Door (global edge)**  
  If you need global scale, edge routing, or multi-region AKS, [Azure Front Door](https://learn.microsoft.com/azure/frontdoor/front-door-overview) can front AKS and route traffic to the private cluster via Firewall.  

- **Azure API Management (full API lifecycle)**  
  For managing public APIs with features like subscriptions, throttling, IP allowlists, and Entra ID authentication, [Azure API Management](https://learn.microsoft.com/azure/api-management/api-management-key-concepts) is often placed in front of AKS ingress.  

- **Service Mesh Gateways (optional)**  
  If you deploy a service mesh (e.g., Istio, Linkerd, Open Service Mesh), the mesh ingress controller can act as your API Gateway with additional routing, retries, and observability.

---

👉 **In this repo**, we focus on the **NGINX Ingress Controller + Cert-Manager** setup as the default API Gateway. For enterprise cases, Azure Application Gateway or API Management can be introduced on top of this architecture.


## Considerations ##

In a production environment with a **private AKS cluster**, applications should not be directly exposed via `LoadBalancer` services. Instead, use an **ingress controller** such as [NGINX Ingress Controller](https://kubernetes.github.io/ingress-nginx/) fronted by **Azure Firewall** (with DNAT rules) or by an **Application Gateway** if advanced L7 capabilities are needed.  

This repo follows the **NGINX Ingress + cert-manager + Azure Firewall** approach, which provides:  
- Path-based and host-based routing  
- Load balancing across pods  
- SSL termination with automated certificate management via Let’s Encrypt  
- Centralized ingress, keeping backend services (`ClusterIP`) private  
- Reduced attack surface, since apps are only reachable via firewall public IP  


### Ingress Controller Options
While this repo uses **NGINX ingress controller**, other common ingress solutions in AKS include:  
- [Azure Application Gateway Ingress Controller (AGIC)](https://learn.microsoft.com/azure/application-gateway/ingress-controller-overview) – fully managed Azure L7 load balancer + WAF  
- [Azure Front Door](https://learn.microsoft.com/azure/frontdoor/front-door-overview) – global load balancing & CDN edge security  
- [Azure API Management](https://learn.microsoft.com/azure/api-management/api-management-key-concepts) – full-featured API gateway  

The choice depends on your requirements:  
- Use **NGINX ingress + Firewall** → simple, cost-effective, Kubernetes-native.  
- Use **AGIC** → tighter Azure integration with WAF and advanced L7 rules.  
- Use **Front Door** → multi-region, edge acceleration, global presence.  
- Use **APIM** → for external APIs requiring subscriptions, rate limiting, and identity integration.

### NGINX Ingress Controller ###

When exposing workloads from the private AKS cluster, this repo uses the [NGINX Ingress Controller](https://kubernetes.github.io/ingress-nginx/) with **cert-manager** for TLS certificates.  
Some useful resources:  

- [NGINX Ingress Controller documentation](https://kubernetes.github.io/ingress-nginx/)  
- [Enable ModSecurity with NGINX ingress](https://kubernetes.github.io/ingress-nginx/user-guide/nginx-configuration/annotations/#modsecurity)  
- [Create an HTTPS ingress controller on AKS](https://learn.microsoft.com/azure/aks/ingress-tls)  
- [Use NGINX ingress with an internal/private IP](https://learn.microsoft.com/azure/aks/ingress-internal-ip)  
- [Use custom TLS certificates with NGINX ingress](https://learn.microsoft.com/azure/aks/ingress-own-tls)  
- [Automated TLS with cert-manager + Let’s Encrypt](https://cert-manager.io/docs/tutorials/acme/nginx-ingress/)  

---

## Test Access to Private AKS Cluster ##

To validate private connectivity:  
- Use **Azure Bastion** to open an SSH session to the jumpbox VM.  
- Run `nslookup` against the AKS API server FQDN. You should see resolution through the **Private DNS Zone**.  

![nslookup](images/nslookup.png)  

**Note**: The Terraform module installs **kubectl** and **Azure CLI** on the jumpbox VM using the [Custom Script Extension](https://learn.microsoft.com/azure/virtual-machines/extensions/custom-script-linux). This lets you manage the AKS cluster directly from the VM.

---

## References & Acknowledgements

This repository has been designed and implemented by combining best practices and ideas from several advanced open-source projects.  
Special thanks to the authors of the following repositories, whose work greatly influenced this implementation:

- [paolosalvatori/private-aks-cluster-terraform-devops](https://github.com/paolosalvatori/private-aks-cluster-terraform-devops)  
  Comprehensive Terraform-based setup for a private AKS cluster, including networking, firewall, and GitHub Actions integration.  

- [paolosalvatori/aks-crossplane-terraform](https://github.com/paolosalvatori/aks-crossplane-terraform)  
  Demonstrates hybrid IaC approaches combining Terraform and Crossplane for advanced AKS management.  

- [markti/terraform-hashitalks-2024](https://github.com/markti/terraform-hashitalks-2024)  
  Modern Terraform project structure and DevOps patterns shared during HashiTalks 2024.  

- [antonputra/tutorials (Lesson 177)](https://github.com/antonputra/tutorials/tree/main/lessons/177)  
  Step-by-step AKS cluster deployment with Terraform, including ingress, monitoring, and GitHub Actions integration.  

---

👉 While this project is inspired by the above, it is **not a direct copy**.  
It brings together the most useful practices into a single repository that:  
- Provisions a **private AKS cluster** with Terraform.  
- Integrates **GitHub Actions + OIDC** for secure CI/CD.  
- Deploys **Helm-based addons** (Ingress, Cert-Manager, Prometheus, Grafana, ArgoCD).  
- Implements a **GitOps workflow** with ArgoCD.  
- Ensures **best-practice networking and security** with Azure Firewall and private endpoints.  









