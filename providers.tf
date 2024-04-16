provider "google" {
  credentials = "${file("C:/Users/danil/Downloads/key/project-7989-55b38bd34710.json")}"
  project     = "project-7989"
  region      = "asia-south1"
  zone        = "asia-south1-a"
}
