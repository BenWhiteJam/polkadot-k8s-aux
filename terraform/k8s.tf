locals {
  panic_network = var.chain == "polkadot" ? "Polkadot CC1" : "Kusama CC3"
}
resource "null_resource" "push_containers" {

  triggers = {
    host = md5(module.terraform-gke-blockchain.kubernetes_endpoint)
    cluster_ca_certificate = md5(
      module.terraform-gke-blockchain.cluster_ca_certificate,
    )
  }
  provisioner "local-exec" {
    command = <<EOF


find ${path.module}/../docker -mindepth 1 -maxdepth 1 -type d  -printf '%f\n'| while read container; do
  
  pushd ${path.module}/../docker/$container
  cp Dockerfile.template Dockerfile
  sed -i "s/((polkadot_version))/${var.polkadot_version}/" Dockerfile
  cat << EOY > cloudbuild.yaml
steps:
- name: 'gcr.io/cloud-builders/docker'
  args: ['build', '-t', "gcr.io/${module.terraform-gke-blockchain.project}/$container:${var.kubernetes_namespace}-latest", '.']
images: ["gcr.io/${module.terraform-gke-blockchain.project}/$container:${var.kubernetes_namespace}-latest"]
EOY
  gcloud builds submit --project ${module.terraform-gke-blockchain.project} --config cloudbuild.yaml .
  rm -v Dockerfile
  rm cloudbuild.yaml
  popd
done
EOF
  }
}

resource "kubernetes_namespace" "polkadot_namespace" {
  metadata {
    name = var.kubernetes_namespace
  }
}

resource "kubernetes_secret" "polkadot_panic_alerter_config_vol" {
  metadata {
    name = "polkadot-panic-alerter-config-vol"
    namespace = var.kubernetes_namespace
  }
  data = {
    "internal_config_alerts.ini" = "${file("${path.module}/../k8s/polkadot-panic-alerter-configs-template/internal_config_alerts.ini")}"
    "internal_config_main.ini" = "${file("${path.module}/../k8s/polkadot-panic-alerter-configs-template/internal_config_main.ini")}"
    "user_config_main.ini" = "${templatefile("${path.module}/../k8s/polkadot-panic-alerter-configs-template/user_config_main.ini", { "telegram_alert_chat_id" : var.telegram_alert_chat_id, "telegram_alert_chat_token": var.telegram_alert_chat_token } )}"
    "user_config_nodes.ini" = "${templatefile("${path.module}/../k8s/polkadot-panic-alerter-configs-template/user_config_nodes.ini", {"polkadot_stash_account_address": var.polkadot_stash_account_address, "kubernetes_namespace": var.kubernetes_namespace, "panic_network": local.panic_network})}"
    "user_config_repos.ini" = "${file("${path.module}/../k8s/polkadot-panic-alerter-configs-template/user_config_repos.ini")}"
  }
  depends_on = [ null_resource.push_containers, kubernetes_namespace.polkadot_namespace ]
}

resource "kubernetes_config_map" "polkadot_api_server_config_vol" {
  metadata {
    name = "polkadot-api-server-config-vol"
    namespace = var.kubernetes_namespace
  }
  data = {
    "user_config_main.ini" = "${file("${path.module}/../k8s/polkadot-api-server-configs-template/user_config_main.ini")}"
    "user_config_main.ini" = "${templatefile("${path.module}/../k8s/polkadot-api-server-configs-template/user_config_nodes.ini", { "kubernetes_namespace" : var.kubernetes_namespace } )}"
  }
  depends_on = [ null_resource.push_containers, kubernetes_namespace.polkadot_namespace ]
}

resource "kubernetes_secret" "polkadot_payout_account_mnemonic" {
  metadata {
    name = "polkadot-payout-account-mnemonic"
    namespace = var.kubernetes_namespace
  }
  data = {
    "payout-account-mnemonic" = var.payout_account_mnemonic
  }
  depends_on = [ null_resource.push_containers, kubernetes_namespace.polkadot_namespace ]
}

resource "local_file" "k8s_kustomization" {
  content = templatefile("${path.module}/../k8s/kustomization.yaml.tmpl",
     { "project" : module.terraform-gke-blockchain.project,
       "polkadot_archive_url": var.polkadot_archive_url,
       "polkadot_version": var.polkadot_version,
       "chain": var.chain,
       "payout_account_address": var.payout_account_address,
       "kubernetes_namespace": var.kubernetes_namespace,
       "kubernetes_name_prefix": var.kubernetes_name_prefix,
       "polkadot_stash_account_address": var.polkadot_stash_account_address})
  filename = "${path.module}/../k8s/kustomization.yaml"
}

resource "null_resource" "apply" {
  provisioner "local-exec" {

    command = <<EOF
set -e
set -x
gcloud container clusters get-credentials "${module.terraform-gke-blockchain.name}" --region="${module.terraform-gke-blockchain.location}" --project="${module.terraform-gke-blockchain.project}"

cd ${path.module}/../k8s
kubectl apply -k .
rm -rvf kustomization.yaml
rm -rvf namespace.yaml
EOF

  }
  depends_on = [ null_resource.push_containers, local_file.k8s_kustomization, kubernetes_namespace.polkadot_namespace ]
}
