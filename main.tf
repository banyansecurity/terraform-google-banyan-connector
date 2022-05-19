terraform {
  required_providers {
    banyan = {
      source  = "banyansecurity/banyan"
      version = "0.6.3"
    }
    google = {
      source  = "hashicorp/google"
      version = "~> 4.21.0"
    }
    time = {
      source  = "hashicorp/time"
      version = "0.7.2"
    }
  }
}

provider "google" {
  project = var.project
  region  = var.region
  zone    = "${var.region}-a"
}

provider "banyan" {
  api_token = var.banyan_api_key
  host      = var.banyan_host
}

locals {
  labels = merge(var.labels, {
    provider = "banyan"
  })
  connector_vm_name = "${var.name_prefix}-connector"
}

resource "banyan_api_key" "connector_key" {
  name        = var.connector_name
  description = var.connector_name
  scope       = "satellite"
}

resource "banyan_connector" "connector_spec" {
  name                 = var.connector_name
  satellite_api_key_id = banyan_api_key.connector_key.id
}

# wait for a connector to be unhealthy before the API objects can be deleted
resource "time_sleep" "connector_health_check" {
  depends_on = [banyan_connector.connector_spec]

  destroy_duration = "5m"
}

locals {
  init_script = <<INIT_SCRIPT
#!/bin/bash
# use the latest, or set the specific version
LATEST_VER=$(curl -sI https://www.banyanops.com/netting/connector/latest | awk '/Location:/ {print $2}' | grep -Po '(?<=connector-)\S+(?=.tar.gz)')
INPUT_VER="${var.package_version}"
VER="$LATEST_VER" && [[ ! -z "$INPUT_VAR" ]] && VER="$INPUT_VER"
# create folder for the Tarball
mkdir -p /opt/banyan-packages
cd /opt/banyan-packages
# download and unzip the files
wget https://www.banyanops.com/netting/connector-$VER.tar.gz
tar zxf connector-$VER.tar.gz
cd connector-$VER
# create the config file
echo 'command_center_url: ${var.banyan_host}' > connector-config.yaml
echo 'api_key_secret: ${banyan_api_key.connector_key.secret}' >> connector-config.yaml
echo 'connector_name: ${var.connector_name}' >> connector-config.yaml
./setup-connector.sh
INIT_SCRIPT
}

resource "google_compute_instance" "connector_vm" {
  depends_on = [time_sleep.connector_health_check]

  name         = "${var.name_prefix}-connector"
  machine_type = var.machine_type

  tags   = [local.connector_vm_name]
  labels = local.labels

  boot_disk {
    initialize_params {
      image = "ubuntu-os-cloud/ubuntu-2004-lts"
    }
  }

  network_interface {
    network = var.network
  }

  metadata_startup_script = local.init_script
}

resource "google_compute_firewall" "connector_ingress" {
  name          = "${var.name_prefix}-connector-management"
  network       = var.network
  direction     = "INGRESS"
  target_tags   = [local.connector_vm_name]
  source_ranges = var.management_cidrs
  allow {
    protocol = "tcp"
    ports    = ["22"]
  }
}

resource "google_compute_firewall" "connector_egress" {
  name          = "${var.name_prefix}-connector-global-edge"
  network       = var.network
  direction     = "EGRESS"
  target_tags   = [local.connector_vm_name]
  destination_ranges = ["0.0.0.0/0"]
  allow {
    protocol = "all"
  }
}

