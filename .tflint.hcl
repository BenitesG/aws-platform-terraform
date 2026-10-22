# ---------------------------------------------------------------------------
# .tflint.hcl
#
# Lint for the Terraform language itself, which `terraform validate` does not
# cover: validate answers "is this syntactically valid and internally
# consistent?", tflint answers "is this the right way to write it?".
#
# Only the bundled `terraform` ruleset is enabled. The AWS ruleset is a
# separate plugin that has to be downloaded by `tflint --init`, and it is a
# deliberate next step rather than an omission - see "What is still open" in
# the README.
#
# WHAT IT CAUGHT ON THE FIRST RUN: twelve findings, all real. None of the six
# child modules declared required_version or required_providers, so each one
# inherited whatever constraint the caller happened to have and carried no
# compatibility contract of its own. Fixed in the modules, not silenced here.
#
# The three remaining findings are suppressed at the declaration itself, with
# `tflint-ignore` and the reason written next to it - never from this file.
# A global suppression would also hide the next variable that really does die.
# ---------------------------------------------------------------------------

config {
  # Lint the local modules as well, not only the root configurations. Without
  # this the module code - where most of the logic lives - is never read.
  call_module_type = "local"
}

plugin "terraform" {
  enabled = true
  preset  = "recommended"
}
