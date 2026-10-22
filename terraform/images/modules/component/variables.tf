# ---------------------------------------------------------------------------
# modules/component/variables.tf
# ---------------------------------------------------------------------------

variable "name" {
  description = "Component name, following the acme-{function} pattern (e.g., acme-timezone)"
  type        = string
}

variable "component_version" {
  description = <<-EOT
    Semantic version of the component (e.g., "1.0.2").

    It is called component_version and not "version" because "version" is a
    RESERVED argument in a module block - Terraform uses it for the registry
    module version and would reject the name.

    CHANGING THE YAML DOES NOT BUMP THIS VERSION ON ITS OWN. It is manual, and
    there are TWO places: here and the recipe_version of the recipe that
    consumes the component, because the component ARN includes the version, so
    changing the component changes the recipe - and the recipe is immutable.
  EOT
  type        = string

  validation {
    condition     = can(regex("^[0-9]+\\.[0-9]+\\.[0-9]+$", var.component_version))
    error_message = "Use a semantic version with three numbers, for example 1.0.0."
  }
}

variable "platform" {
  description = "Component platform: Linux or Windows"
  type        = string
  default     = "Linux"

  validation {
    condition     = contains(["Linux", "Windows"], var.platform)
    error_message = "platform must be Linux or Windows."
  }
}

variable "description" {
  description = "What the component does. Shows up in the console and in the build log."
  type        = string
  default     = null
}

variable "data" {
  description = "Content of the AWSTOE document in YAML. Use file() at the call site."
  type        = string
}

variable "supported_os_versions" {
  description = "Supported OS versions. Empty list = no restriction."
  type        = list(string)
  default     = []
}
