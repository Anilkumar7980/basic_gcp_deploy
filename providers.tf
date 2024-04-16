provider "google" {
  credentials = "${{ secrets.GCP_SA_KEY }}
  project     = "project-7989"
  region      = "asia-south1"
  zone        = "asia-south1-a"
}
