
resource "google_compute_network" "pre_sales_vpc" {
  name                    = "pre-sales-vpc"
  auto_create_subnetworks = false
  routing_mode            = "GLOBAL"
}






resource "google_compute_subnetwork" "public_subnet" {
  name                     = "public-subnet"
  ip_cidr_range            = "10.0.1.0/24"
  region                   = "asia-south1"
  network                  = google_compute_network.pre_sales_vpc.self_link
  private_ip_google_access = false
  log_config {
    aggregation_interval = "INTERVAL_10_MIN"
    flow_sampling        = 0.7
    metadata             = "INCLUDE_ALL_METADATA"
  }
  description = "Jump-box subnet for securely access to the GKE and PostgreSQL"
}

resource "google_compute_subnetwork" "private_subnet" {
  name                     = "private-subnet"
  ip_cidr_range            = "10.0.2.0/24"
  region                   = "asia-south1"
  network                  = google_compute_network.pre_sales_vpc.self_link
  private_ip_google_access = true
  log_config {
    aggregation_interval = "INTERVAL_10_MIN"
    flow_sampling        = 0.7
    metadata             = "INCLUDE_ALL_METADATA"
  }
  description = "Subnet for GKE Auto-pilot-cluster and PostgreSQL for secure access"
}


#****************************************************GKE AUTO-PILOT-PRIVATE-cluster********************************************************************


resource "google_container_cluster" "auto_private_cluster" {
  name     = "auto-private-cluster"
  location = "asia-south1"
  project  = "project-7989"
  deletion_protection = "false"

  network    = google_compute_network.pre_sales_vpc.self_link
  subnetwork = google_compute_subnetwork.private_subnet.self_link

  # Enable Autopilot mode
  enable_autopilot = true

  private_cluster_config {
    enable_private_endpoint = true
    enable_private_nodes    = true
    master_ipv4_cidr_block  = "172.16.0.0/28"
  }

  ip_allocation_policy {
    # These settings are generally managed automatically by Autopilot
    # but specifying the subnetwork is still required
  }

  master_authorized_networks_config {
    cidr_blocks {
      cidr_block   = "10.0.1.0/24"
      display_name = "jump-box"
    }
  }
}

# Kubernetes provider configuration
provider "kubernetes" {
  host                   = google_container_cluster.auto_private_cluster.endpoint
  token                  = data.google_client_config.default.access_token
  cluster_ca_certificate = base64decode(google_container_cluster.auto_private_cluster.master_auth[0].cluster_ca_certificate)
}


#**********************************************************POSTGRESQL WITH PRIVATE IP*****************************************************************
        
resource "google_compute_global_address" "private_ip_block" {
  name         = "private-ip-block"
  purpose      = "VPC_PEERING"
  address_type = "INTERNAL"
  ip_version   = "IPV4"
  prefix_length = "20"
  network       = google_compute_network.pre_sales_vpc.self_link
}

resource "google_service_networking_connection" "private_vpc_connection" {
  network                 = google_compute_network.pre_sales_vpc.self_link
  service                 = "servicenetworking.googleapis.com"
  reserved_peering_ranges = [google_compute_global_address.private_ip_block.name]
}

resource "random_id" "db_name_suffix" {
  byte_length = "4"
}

resource "google_sql_database" "postgresql" {
  name     = "postgresql"
  instance = google_sql_database_instance.postgresql.name
}
resource "google_sql_database_instance" "postgresql" {
  name             = "postgresql"
  database_version = "POSTGRES_14"
  depends_on       = [google_service_networking_connection.private_vpc_connection]
  settings {
    tier              = "db-f1-micro"
    availability_type = "REGIONAL"
    disk_size         = "10"  # 10 GB is the smallest disk size
    ip_configuration {
      ipv4_enabled    = "false"
      private_network = google_compute_network.pre_sales_vpc.self_link
    }
  }
}
resource "google_sql_user" "db_user" {
  name     = var.dbuser
  instance = google_sql_database_instance.postgresql.name
  password = var.dbpassword
}


variable "dbuser" {
  description = "Username for the PostgreSQL database"
  type        = string
}

variable "dbpassword" {
  description = "Password for the PostgreSQL database user"
  type        = string
  sensitive   = true  // This will prevent the password from being displayed in logs
}

##################################################################JUMP-BOX-WINDOWS#####################################################

resource "google_compute_instance" "jump_box" {
  project             = "project-7989"
  name                = "jump-box"
  machine_type        = "n2-standard-2"
  zone                = "asia-south1-b"
  deletion_protection = "false"
  depends_on = [google_compute_subnetwork.public_subnet]

  boot_disk {
    initialize_params {
      image = "windows-cloud/windows-2019"
      size  = 50
    }
  }

  network_interface {
    network    = "pre-sales-vpc"  // Reference to the network
    subnetwork = "public-subnet"  // Reference to the subnet

    // Specifying access_config with no arguments assigns an ephemeral public IP
    access_config {
      // Leaving it empty will assign an ephemeral IP
    }
  }


  // Enable IAP-based access
  tags = ["jump-box"]
  service_account {
    scopes = ["https://www.googleapis.com/auth/cloud-platform"]
  }
}


############################################################FIREWALL-RULES#######################################################

resource "google_compute_firewall" "iap_to_windows" {
  name    = "iap-to-windows"
  network = "pre-sales-vpc"
  depends_on = [google_compute_network.pre_sales_vpc]

  allow {
    protocol = "tcp"
    ports    = ["3389"]
  }

  source_ranges = ["35.235.240.0/20"]  // CIDR for IAP access, adjust if needed based on Google's current recommendations
  target_tags   = ["jump-box"]  // The tag used in the Windows VM
}



resource "google_compute_firewall" "windows_to_gke_postgres" {
  name    = "windows-to-gke-postgres"
  network = "pre-sales-vpc"
  depends_on = [google_compute_network.pre_sales_vpc]

  allow {
    protocol = "tcp"
    ports    = ["5432", "8080", "80", "443"]  // Adjust ports as necessary for your applications in GKE
  }

  source_tags   = ["jump-box"]  // Assuming your Windows VM is tagged as 'jump-box'
  target_tags   = ["gke-cluster", "postgresql"]
}


resource "google_compute_firewall" "gke_to_postgres" {
  name    = "gke-to-postgres"
  network = "pre-sales-vpc"
  depends_on = [google_compute_network.pre_sales_vpc]

  allow {
    protocol = "tcp"
    ports    = ["5432"]  // PostgreSQL port
  }

  source_tags   = ["auto-pilot-cluster"]  // Assuming your GKE nodes are tagged as 'gke-cluster'
  target_tags   = ["postgresql"]   // PostgreSQL VM/tag
}

