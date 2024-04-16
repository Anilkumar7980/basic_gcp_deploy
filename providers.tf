provider "google" {
  credentials = file("google-credentials.json")
  project     = "project-7989"
  region      = "asia-south1"
  zone        = "asia-south1-a"
}
