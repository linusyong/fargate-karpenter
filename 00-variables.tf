variable "profile" {
  description = "AWS Profile Name"
  type        = string
}

variable "region" {
  description = "The aws region. https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/using-regions-availability-zones.html"
  type        = string
}

variable "vpc_cidr" {
  description = "The CIDR block for the VPC. Default value is a valid CIDR, but not acceptable by AWS and should be overridden"
  type        = string
}

variable "subnet_cidr_bits" {
  description = "Subnit bit for each subnet"
  type        = number
}

variable "project" {
  description = "Project name"
  type        = string
}

variable "tags" {
  description = "A map of tags to add to all resources"
  type        = map(string)
  default = {
    "Project"     = "linus-sandbox-eks"
    "Environment" = "sandbox"
    "Owner"       = "linus.yong"
  }
}

variable "cluster_version" {
  default = "1.27"
}