##################################################################
#_____ PROVIDER _________________________________________________#
##################################################################
aws_configs = {
  region = "us-west-2"
  # Aplicadas via default_tags a TODOS os recursos que suportam tags
  # (instância, EBS, ENI, SG, key pair, S3, IAM, etc.).
  default_tags = {
    "ChargeType"                        = "dedicated"
    "ManagedBy"                         = "terraform"
    "CC"                                = "swe"
    "Name"                              = "acme-swe-nonprod-App22"
    "Owner"                             = "platform-team@acme.example"
    "RequestId"                         = "ticketing-system_4966"
    "Schedule"                          = "business-hours"
    "mb:automation:Environment"         = "nonprod"
    "mb:backup:Frequencies"             = "none"
    "acme:cost-allocation:Application"  = "App"
    "acme:cost-allocation:BusinessUnit" = "a-definir"
    "acme:cost-allocation:CostCenter"   = "a-definir"
    "acme:cost-allocation:Department"   = "swe"
    "acme:cost-allocation:Project"      = "App"
    "mb:data:DataClassification"        = "interno"
  }
}

##################################################################
#_____ NETWORK __________________________________________________#
##################################################################
network = {
  subnet_id = "subnet-0a1b2c3d4e5f70001" # TODO: subnet privada do site App
  vpc_id    = "vpc-0a1b2c3d4e5f60001"
}

##################################################################
#_____ SERVERS (App / Windows Server 2025) ____________________#
##################################################################
# Cada servidor define seu próprio objeto. Campos omitidos usam o default do
# schema em variables.tf (instance_type t3a.micro, root 60 GB, gp3).
# Todas as máquinas deste site são t3a.2xlarge (8 vCPU / 32 GB).
servers = {
  WIN-APP-GR11 = {
    role          = "App Repository & License Server"
    instance_type = "t3a.2xlarge"
    data_disks    = [{ size = 150, device_name = "xvdf" }] # E:
    ami_id        = "ami-0a1b2c3d4e5fb0007"
  }

  WIN-APP-HS11 = {
    role          = "History (DataStore)"
    instance_type = "t3a.2xlarge"
    data_disks    = [{ size = 100, device_name = "xvdf" }] # E: -- TODO: confirmar tamanho (veio truncado)
    ami_id        = "ami-0a1b2c3d4e5fb0007"
  }

  # WIN-APP-OM11 = {
  #   role          = "Primary OMI Display (Runtime)"
  #   instance_type = "t3a.2xlarge"
  #   data_disks    = [{ size = 50, device_name = "xvdf" }] # E:
  #   ami_id = "ami-0a1b2c3d4e5fb0007"
  # }

  # WIN-APP-AO11 = {
  #   role          = "Primary AOS1 (Application Object Server)"
  #   instance_type = "t3a.2xlarge"
  #   data_disks    = [{ size = 50, device_name = "xvdf" }] # E:
  #   ami_id = "ami-0a1b2c3d4e5fb0007"
  # }

  # WIN-APP-OI11 = {
  #   role          = "Primary OI/DAS1 (drivers / TOP Server)"
  #   instance_type = "t3a.2xlarge"
  #   data_disks    = [{ size = 100, device_name = "xvdf" }] # E:
  #   ami_id = "ami-0a1b2c3d4e5fb0007"
  # }

  # WIN-APP-OI12 = {
  #   role          = "OI/DAS dedicado ao monitoramento de baterias Li-Ion"
  #   instance_type = "t3a.2xlarge"
  #   data_disks    = [{ size = 100, device_name = "xvdf" }] # E:
  #   ami_id = "ami-0a1b2c3d4e5fb0007"
  # }

  # WIN-APP-DE11 = {
  #   role          = "Primary Dev (IDE / programação de CLP)"
  #   instance_type = "t3a.2xlarge"
  #   data_disks    = [{ size = 100, device_name = "xvdf" }] # E:
  #   ami_id = "ami-0a1b2c3d4e5fb0007"
  # }
}
