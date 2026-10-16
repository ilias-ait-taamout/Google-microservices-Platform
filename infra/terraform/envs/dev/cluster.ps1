<#
=============================================================================
 cluster.ps1 — everyday commands for the dev cluster (Windows / PowerShell)
=============================================================================
 Usage, from infra/terraform/envs/dev:

   .\cluster.ps1 plan          show what would change
   .\cluster.ps1 up            apply - creates the cluster (~10 min)
   .\cluster.ps1 down          DESTROY EVERYTHING            <- end of each day
   .\cluster.ps1 orphans       scan the region for anything left behind
   .\cluster.ps1 stop          halt the EC2s, keep the disks (middle ground)
   .\cluster.ps1 start         boot them again (public IPs CHANGE)
   .\cluster.ps1 status        instance states
   .\cluster.ps1 kubeconfig    fetch kubeconfig from the control plane
   .\cluster.ps1 nodes         kubectl get nodes -o wide
   .\cluster.ps1 ip            update admin_cidr to your current public IP

 DAILY WORKFLOW
   morning:  .\cluster.ps1 up   then  .\cluster.ps1 kubeconfig
   evening:  .\cluster.ps1 down then  .\cluster.ps1 orphans

 Skip the confirmation prompt with -Yes:
   .\cluster.ps1 down -Yes

 If PowerShell refuses to run this:
   Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
=============================================================================
#>

param(
    [Parameter(Position = 0)]
    [ValidateSet('help', 'init', 'fmt', 'validate', 'plan', 'up', 'down', 'orphans',
                 'stop', 'start', 'status', 'kubeconfig', 'nodes', 'ip')]
    [string]$Command = 'help',

    [switch]$Yes
)

$ErrorActionPreference = 'Stop'

$Profile_ = 'terraform-mgp'
$Region   = 'eu-west-3'
$Project  = 'gmp'
$Env_     = 'dev'

function Get-InstanceIds {
    # Read instance IDs out of Terraform state, so we only ever touch THIS
    # environment's nodes and nothing else in the account.
    $json = terraform output -json all_instance_ids
    return ($json | ConvertFrom-Json)
}

function Get-ServerIp {
    aws ec2 describe-instances --profile $Profile_ --region $Region `
        --filters "Name=tag:Name,Values=$Project-$Env_-server" "Name=instance-state-name,Values=running" `
        --query 'Reservations[0].Instances[0].PublicIpAddress' --output text
}

function Test-KubernetesLoadBalancers {
    <#
      THE ONE THING THAT BREAKS terraform destroy.

      If Kubernetes created a Service of type LoadBalancer, AWS made a real
      load balancer that Terraform knows nothing about. That LB holds network
      interfaces inside your subnets, so `terraform destroy` hangs for ~20
      minutes on the subnet and then fails with "DependencyViolation".

      Terraform did not create it, so Terraform cannot delete it.
      You delete the Service first, or the LB by hand.
    #>
    try {
        $lbs = aws elbv2 describe-load-balancers --profile $Profile_ --region $Region `
                 --query 'LoadBalancers[].LoadBalancerName' --output text 2>$null
        $classic = aws elb describe-load-balancers --profile $Profile_ --region $Region `
                 --query 'LoadBalancerDescriptions[].LoadBalancerName' --output text 2>$null
    } catch { return }

    if (($lbs -and $lbs -ne 'None') -or ($classic -and $classic -ne 'None')) {
        Write-Host ""
        Write-Host "  WARNING: load balancers exist in $Region :" -ForegroundColor Yellow
        if ($lbs -and $lbs -ne 'None')       { Write-Host "    $lbs" }
        if ($classic -and $classic -ne 'None') { Write-Host "    $classic" }
        Write-Host ""
        Write-Host "  If Kubernetes created these (a Service of type LoadBalancer)," -ForegroundColor Yellow
        Write-Host "  destroy WILL fail on the subnets. Delete them first:" -ForegroundColor Yellow
        Write-Host "    kubectl delete svc --all --all-namespaces --field-selector spec.type=LoadBalancer"
        Write-Host ""
    }
}

switch ($Command) {

    'help' {
        Write-Host ""
        Write-Host "  DAILY" -ForegroundColor Cyan
        Write-Host "    up          build the cluster (~10 min)"
        Write-Host "    down        DESTROY everything      <- end of each day"
        Write-Host "    orphans     verify nothing is left behind"
        Write-Host ""
        Write-Host "  ALTERNATIVE TO DESTROY" -ForegroundColor Cyan
        Write-Host "    stop        halt EC2s, keep disks and cluster state (~2 EUR/week)"
        Write-Host "    start       boot them again (public IPs change)"
        Write-Host ""
        Write-Host "  EVERYDAY" -ForegroundColor Cyan
        Write-Host "    plan / validate / fmt / status"
        Write-Host "    kubeconfig  fetch kubeconfig from the control plane"
        Write-Host "    nodes       kubectl get nodes -o wide"
        Write-Host "    ip          your home IP changed and everything times out"
        Write-Host ""
    }

    'init'     { terraform init }
    'fmt'      { terraform fmt -recursive ..\.. }
    'validate' { terraform validate }
    'plan'     { terraform plan }

    'up' {
        terraform apply
        Write-Host ""
        Write-Host "k3s needs ~3 more minutes to finish installing." -ForegroundColor Yellow
        Write-Host "Then run: .\cluster.ps1 kubeconfig" -ForegroundColor Yellow
    }

    # -------------------------------------------------------------------------
    # DESTROY
    # -------------------------------------------------------------------------
    'down' {
        Test-KubernetesLoadBalancers

        if (-not $Yes) {
            Write-Host "This destroys the VPC, all 3 EC2 instances, their disks," -ForegroundColor Red
            Write-Host "and everything running on the cluster. Not recoverable." -ForegroundColor Red
            Write-Host ""
            Write-Host "Kept (not managed by Terraform): the S3 state bucket." -ForegroundColor DarkGray
            Write-Host ""
            $answer = Read-Host "Type 'destroy' to confirm"
            if ($answer -ne 'destroy') { Write-Host "Cancelled."; break }
        }

        terraform destroy -auto-approve

        # Local kubeconfig now points at instances that no longer exist.
        if (Test-Path .\kubeconfig-dev.yaml) {
            Remove-Item .\kubeconfig-dev.yaml
            Write-Host "removed stale kubeconfig-dev.yaml" -ForegroundColor DarkGray
        }

        Write-Host ""
        Write-Host "Destroyed. Verifying nothing was left behind..." -ForegroundColor Green
        Write-Host ""
        & $PSCommandPath orphans
    }

    # -------------------------------------------------------------------------
    # ORPHAN SCAN — the part that actually gives you confidence
    # -------------------------------------------------------------------------
    # `terraform destroy` only removes what is in ITS state file. Anything
    # created outside Terraform - by Kubernetes, by a console click, by a
    # half-finished apply - survives and keeps billing. This checks for the
    # four things that actually cost money.
    'orphans' {
        Write-Host "Scanning $Region for leftovers..." -ForegroundColor Cyan
        Write-Host ""
        $clean     = $true
        $unchecked = @()

        # Runs one AWS query. Returns the output, or $null.
        # Critically: distinguishes "nothing found" from "the call FAILED".
        # A denied or errored call returns empty, which would otherwise read as
        # "all clear" — the exact false negative that lets a resource keep billing.
        function Invoke-Check {
            param([string]$Label, [string[]]$AwsArgs)

            # $ErrorActionPreference = 'Stop' is set at the top of this script.
            # Under it, ANY native command that writes to stderr raises a
            # terminating NativeCommandError - even when the command succeeded.
            # The aws CLI writes warnings and access-denied text to stderr, so
            # we drop to 'Continue' for the duration of the call.
            $prevEAP = $ErrorActionPreference
            $ErrorActionPreference = 'Continue'
            try {
                $raw  = & aws @AwsArgs 2>&1
                $code = $LASTEXITCODE
            }
            finally {
                $ErrorActionPreference = $prevEAP
            }

            # 2>&1 interleaves stderr as ErrorRecord objects. Split them out so
            # stdout stays usable and the error text stays readable.
            $errText = ($raw | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] } |
                        ForEach-Object { $_.ToString() }) -join ' '
            $stdout  = $raw | Where-Object { -not ($_ -is [System.Management.Automation.ErrorRecord]) } |
                       Where-Object { $_ -and "$_".Trim() -ne '' }

            # A failed call returns nothing, which would otherwise read as
            # "all clear" - the false negative this whole function exists to stop.
            if ($code -ne 0) {
                $script:unchecked += $Label
                if ($errText -match 'AccessDenied|not authorized') {
                    Write-Host "  ! $Label - NOT CHECKED (access denied)" -ForegroundColor Yellow
                } else {
                    $short = if ($errText.Length -gt 140) { $errText.Substring(0,140) + '...' } else { $errText }
                    Write-Host "  ! $Label - NOT CHECKED ($short)" -ForegroundColor Yellow
                }
                return $null
            }

            return $stdout
        }

        # --- EC2 instances (anything not already terminated) ---
        $inst = Invoke-Check -Label "EC2 instances" -AwsArgs @(
            'ec2','describe-instances','--profile',$Profile_,'--region',$Region,
            '--filters','Name=instance-state-name,Values=pending,running,stopping,stopped',
            '--query','Reservations[].Instances[].{Name:Tags[?Key==`Name`]|[0].Value,Id:InstanceId,State:State.Name,Type:InstanceType}',
            '--output','text')
        if ($inst) {
            Write-Host "EC2 INSTANCES still alive (billing):" -ForegroundColor Red
            Write-Host $inst
            $clean = $false
        }

        # --- EBS volumes not attached to anything ---
        # These survive if delete_on_termination was ever false, and they bill
        # at ~0.09 EUR/GiB/month doing absolutely nothing.
        $vols = Invoke-Check -Label "EBS volumes" -AwsArgs @(
            'ec2','describe-volumes','--profile',$Profile_,'--region',$Region,
            '--filters','Name=status,Values=available',
            '--query','Volumes[].{Id:VolumeId,Size:Size,Created:CreateTime}',
            '--output','text')
        if ($vols) {
            Write-Host "UNATTACHED EBS VOLUMES (billing):" -ForegroundColor Red
            Write-Host $vols
            $clean = $false
        }

        # --- Elastic IPs not associated ---
        # AWS charges for an EIP precisely when it is NOT in use.
        $eips = Invoke-Check -Label "Elastic IPs" -AwsArgs @(
            'ec2','describe-addresses','--profile',$Profile_,'--region',$Region,
            '--query','Addresses[?AssociationId==null].{IP:PublicIp,Alloc:AllocationId}',
            '--output','text')
        if ($eips) {
            Write-Host "UNASSOCIATED ELASTIC IPs (billing):" -ForegroundColor Red
            Write-Host $eips
            $clean = $false
        }

        # --- Load balancers (Kubernetes creates these behind Terraform's back) ---
        # Needs elasticloadbalancing:DescribeLoadBalancers in the IAM policy.
        # This is the check that matters most from Phase 2 onward: an ELB made by
        # a Service of type LoadBalancer is invisible to Terraform and blocks
        # `terraform destroy` on the subnets.
        $lbs = Invoke-Check -Label "Load balancers (v2)" -AwsArgs @(
            'elbv2','describe-load-balancers','--profile',$Profile_,'--region',$Region,
            '--query','LoadBalancers[].{Name:LoadBalancerName,Type:Type}',
            '--output','text')
        if ($lbs) {
            Write-Host "LOAD BALANCERS (billing, ~16 EUR/month each):" -ForegroundColor Red
            Write-Host $lbs
            $clean = $false
        }

        $clbs = Invoke-Check -Label "Load balancers (classic)" -AwsArgs @(
            'elb','describe-load-balancers','--profile',$Profile_,'--region',$Region,
            '--query','LoadBalancerDescriptions[].LoadBalancerName',
            '--output','text')
        if ($clbs) {
            Write-Host "CLASSIC LOAD BALANCERS (billing):" -ForegroundColor Red
            Write-Host $clbs
            $clean = $false
        }

        # --- NAT gateways (we create none, but a stray one is 32 EUR/month) ---
        $nats = Invoke-Check -Label "NAT gateways" -AwsArgs @(
            'ec2','describe-nat-gateways','--profile',$Profile_,'--region',$Region,
            '--filter','Name=state,Values=available,pending',
            '--query','NatGateways[].NatGatewayId',
            '--output','text')
        if ($nats) {
            Write-Host "NAT GATEWAYS (billing, ~32 EUR/month each):" -ForegroundColor Red
            Write-Host $nats
            $clean = $false
        }

        # --- VPCs tagged for this project (free, but means destroy did not finish) ---
        $vpcs = Invoke-Check -Label "Project VPC" -AwsArgs @(
            'ec2','describe-vpcs','--profile',$Profile_,'--region',$Region,
            '--filters',"Name=tag:Project,Values=$Project",
            '--query','Vpcs[].VpcId',
            '--output','text')
        if ($vpcs) {
            Write-Host "PROJECT VPC still exists (free, but destroy did not complete):" -ForegroundColor Yellow
            Write-Host $vpcs
            $clean = $false
        }

        Write-Host ""
        if (-not $clean) {
            Write-Host "  LEFTOVERS FOUND - anything above is still on your bill." -ForegroundColor Red
        }
        elseif ($unchecked.Count -gt 0) {
            Write-Host "  PARTIALLY CLEAN - everything checked is clear, but these" -ForegroundColor Yellow
            Write-Host "  could not be verified: $($unchecked -join ', ')" -ForegroundColor Yellow
            Write-Host "  Fix the IAM permissions, or check them in the console." -ForegroundColor Yellow
        }
        else {
            Write-Host "  CLEAN - nothing is billing in $Region." -ForegroundColor Green
            Write-Host "  Only the S3 state bucket remains, which costs a few cents." -ForegroundColor DarkGray
        }
        Write-Host ""
    }

    # -------------------------------------------------------------------------
    # STOP / START — the middle ground when you want the cluster back tomorrow
    # -------------------------------------------------------------------------
    'stop' {
        $ids = Get-InstanceIds
        Write-Host "Stopping: $($ids -join ', ')"
        aws ec2 stop-instances --profile $Profile_ --region $Region `
            --instance-ids $ids --query 'StoppingInstances[].InstanceId' --output text
        Write-Host ""
        Write-Host "Stopped. Paying for EBS only (~2 EUR/week for 90 GiB)." -ForegroundColor Green
        Write-Host "Cluster state and everything deployed on it survives." -ForegroundColor DarkGray
    }

    'start' {
        $ids = Get-InstanceIds
        Write-Host "Starting: $($ids -join ', ')"
        aws ec2 start-instances --profile $Profile_ --region $Region `
            --instance-ids $ids --query 'StartingInstances[].InstanceId' --output text
        Write-Host ""
        Write-Host "Public IPs have CHANGED. Wait ~60s, then: .\cluster.ps1 kubeconfig" -ForegroundColor Yellow
    }

    'status' {
        aws ec2 describe-instances --profile $Profile_ --region $Region `
            --filters "Name=tag:Project,Values=$Project" "Name=tag:Environment,Values=$Env_" `
            --query 'Reservations[].Instances[].{Name:Tags[?Key==`Name`]|[0].Value,State:State.Name,Type:InstanceType,IP:PublicIpAddress}' `
            --output table
    }

    'kubeconfig' {
        $ip = Get-ServerIp
        if (-not $ip -or $ip -eq 'None') { throw "Control plane is not running. Try: .\cluster.ps1 up" }

        Write-Host "control plane: $ip"
        scp -o StrictHostKeyChecking=no "ubuntu@${ip}:~/.kube/config" ".\kubeconfig-dev.yaml"

        # The node writes its own public IP into the kubeconfig at boot, but
        # that IP changes on every rebuild - so rewrite it every time.
        (Get-Content .\kubeconfig-dev.yaml) `
            -replace 'https://.*:6443', "https://${ip}:6443" |
            Set-Content .\kubeconfig-dev.yaml

        Write-Host ""
        Write-Host "written to .\kubeconfig-dev.yaml" -ForegroundColor Green
        Write-Host "now run:  `$env:KUBECONFIG = `"$PWD\kubeconfig-dev.yaml`""
    }

    'nodes' {
        $env:KUBECONFIG = "$PWD\kubeconfig-dev.yaml"
        kubectl get nodes -o wide
    }

    'ip' {
        $new = (Invoke-RestMethod -Uri 'https://checkip.amazonaws.com').Trim()
        Write-Host "your public IP is $new"

        if (-not (Test-Path .\terraform.tfvars)) { throw "terraform.tfvars not found. Copy it from terraform.tfvars.example first." }

        (Get-Content .\terraform.tfvars) `
            -replace '^admin_cidr.*', "admin_cidr = `"$new/32`"" |
            Set-Content .\terraform.tfvars

        Write-Host "terraform.tfvars updated - now run: .\cluster.ps1 up" -ForegroundColor Green
    }
}
