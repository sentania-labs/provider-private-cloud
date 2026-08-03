# Lab environment. Non-secret topology only -- no credentials, no client
# secrets. See README.md for the full list of values that must be supplied
# separately via TF_VAR_* before a first apply.

vcfa_url    = "https://vcf-lab-automation.int.sentania.net"
region_name = "vcf-lab-region01"

content_libraries = {
  provider_library = {
    name                = "vcf-lab-content-library"
    storage_class_names = ["iscsi-default-policy"]
    items               = []
    subscription_config = {
      subscription_url = "https://vcf-lab-vcenter-mgmt.int.sentania.net:443/cls/vcsp/lib/84ca4972-b3b4-4600-9f02-4634054269ad/lib.json"
    }
  }
}
