terraform {
  required_version = ">= 1.14.0"
  required_providers {
    vcfa = {
      source  = "vmware/vcfa"
      version = "~> 1.2"
    }
    restapi = {
      source  = "Mastercard/restapi"
      version = "~> 3.0.0"
    }
  }
}
