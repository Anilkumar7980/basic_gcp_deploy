terraform {
  backend "gcs" {
    bucket = "backend_state"
    prefix = "terraform/state"
  }
}
