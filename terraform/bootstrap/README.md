# Bootstrap — the Terraform state bucket

Creates the S3 bucket `acme-swe-prod-tfstate`, which holds the state of the
other configurations in the repository.

**Runs once.** After that you probably do not come back here, except to change
something about the bucket.

---

## Why there is a directory just for this

A circular problem: the bucket that holds the state cannot be managed by the
state that does not exist yet.

The way out is to do it in **two steps** — run with local state first, then
move the state into the freshly created bucket. The result is a
Terraform-managed bucket whose state lives inside itself. It sounds
paradoxical, but the ordering resolves it. It is the pattern most people use.

---

## Running it

```powershell
$env:AWS_PROFILE = "acme-swe-prod"
cd bootstrap
```

### Step 1 — local state

This directory **has no** `backend` block at this moment, on purpose.

```powershell
terraform init      # no backend: state stays LOCAL
terraform plan      # check: 5 to add
terraform apply
```

It is worth opening the `terraform.tfstate` that appeared in the folder and
taking a look. It is Terraform's "job logbook": the link between the name you
gave in the code and the real object on AWS. Seeing the contents is clearer
than any explanation.

### Step 2 — migrate to the bucket

Create `backend.tf`:

```hcl
terraform {
  backend "s3" {
    bucket       = "acme-swe-prod-tfstate"
    key          = "bootstrap/terraform.tfstate"
    region       = "us-west-2"
    encrypt      = true
    use_lockfile = true
  }
}
```

```powershell
terraform init -migrate-state    # answer "yes"
terraform plan                   # must say "No changes"
```

The `No changes` is the proof that the new state is intact and Terraform
managed to read from S3. Only then delete the local leftovers:

```powershell
Remove-Item terraform.tfstate, terraform.tfstate.backup -ErrorAction SilentlyContinue
```

---

## What you need to know

### "One bucket" is five resources

Versioning, encryption, public access block and lifecycle **are not fields of
the bucket**: they are separate resources that point to it. Terraform mirrors
the S3 API, where `CreateBucket`, `PutBucketVersioning`, `PutBucketEncryption`,
`PutPublicAccessBlock` and `PutBucketLifecycleConfiguration` are distinct
operations. The console's single form hides this.

If you find an example on the internet with `versioning { }` inside the
`aws_s3_bucket`, it is old material — the provider changed.

### The `backend` block does not accept variables

No `var.*` there. It has to be a literal. It is a Terraform limitation.

And it **does not inherit** the `profile` from the `provider` block: it is
initialized earlier, with its own credential chain. Hence the `AWS_PROFILE`
environment variable.

### `use_lockfile` requires Terraform >= 1.10

Locks the state using S3 itself, dispensing with DynamoDB. On an earlier
version, switch to `dynamodb_table` and create the table.

The lock prevents two simultaneous `apply` runs — you and the CI pipeline, for
example — from reading the same state, both deciding to create, and leaving the
state inconsistent.

### Versioning here is required

Every `apply` writes a new version of the state. If a state gets corrupted, or
if someone runs an improper `destroy`, you can restore the previous version and
regain control of the resources. **It is Terraform's undo.**

That is why there is **no** old-version expiration rule on this bucket, unlike
the flow logs bucket. Each version is a few KB, and deleting old versions would
throw away the ability to recover.

### `prevent_destroy` on the bucket

Prevents a `terraform destroy` from deleting the bucket that holds this
configuration's own state — the destroy would sabotage itself, wiping the
record in the middle of the operation and leaving orphaned resources.

### `moved` blocks

There are `moved` blocks in `main.tf`, left over from renaming the identifiers
from Portuguese to English. They tell Terraform "this resource changed its
name, it is the same object" — without them Terraform would conclude that the
old one was removed and would try to **destroy and recreate** the bucket.

**They can be removed**, since the `apply` that consumed them was successful.
They were kept as an example of the mechanism.

### The bucket is not in `.gitignore`, the state is

`*.tfstate` and `*.tfvars` never go to git. The `.terraform.lock.hcl` does.
