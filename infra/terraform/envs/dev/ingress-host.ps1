<#
=============================================================================
 ingress-host.ps1 - realigne les noms d'hotes des Ingress sur l'IP du cluster
=============================================================================

 POURQUOI CE SCRIPT EXISTE

 Les Ingress exposent chaque environnement sur <env>.<ip>.sslip.io. sslip.io
 resout n'importe quel nom contenant une adresse IP vers cette adresse, ce qui
 donne un Ingress a nom d'hote sans acheter de domaine ni exploiter un DNS.

 Mais l'adresse publique du cluster change a CHAQUE reconstruction, et ce nom
 d'hote vit dans Git. Git ne peut pas connaitre l'adresse d'un cluster qui
 n'existe pas encore : c'est une limite reelle du GitOps, pas un defaut de
 configuration. Les reponses habituelles - un vrai domaine avec son DNS, une
 adresse IP elastique, ExternalDNS - sont toutes ecartees par les arbitrages de
 cout du projet : pas de NAT, pas d'EIP, pas de domaine.

 Il reste donc une etape, et ce script la reduit a une commande.

 USAGE

   .\ingress-host.ps1          affiche ce qui changerait, ne touche a rien
   .\ingress-host.ps1 -Write   reecrit les trois fichiers

 Puis il faut COMMITER ET POUSSER : ArgoCD lit Git, pas le disque local.
=============================================================================
#>
param([switch]$Write)

$ErrorActionPreference = 'Stop'

$repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..\..')).Path

Push-Location $PSScriptRoot
try {
    $ip = (terraform output -raw server_public_ip).Trim()
}
finally {
    Pop-Location
}

if ($ip -notmatch '^\d{1,3}(\.\d{1,3}){3}$') {
    throw "Adresse IP inattendue : '$ip'. Le cluster est-il allume ?"
}

Write-Host "IP publique du cluster : $ip" -ForegroundColor Cyan
Write-Host ""

$changed = 0
foreach ($env in @('dev', 'staging', 'prod')) {
    $path = Join-Path $repo "kustomize\overlays\$env\ingress.yaml"
    if (-not (Test-Path $path)) { Write-Warning "absent : $path"; continue }

    $content = [IO.File]::ReadAllText($path)
    $wanted  = "$env.$ip.sslip.io"

    # On ne touche QUE la ligne `host:`, jamais les commentaires alentour.
    $new = [regex]::Replace($content, '(?m)^(\s*- host:\s*).*$', "`${1}$wanted")

    $current = ([regex]::Match($content, '(?m)^\s*- host:\s*(\S+)')).Groups[1].Value

    if ($current -eq $wanted) {
        Write-Host ("  {0,-8} deja a jour : {1}" -f $env, $wanted)
        continue
    }

    Write-Host ("  {0,-8} {1}" -f $env, $current) -ForegroundColor DarkYellow
    Write-Host ("  {0,-8}  -> {1}" -f '', $wanted) -ForegroundColor Green
    $changed++

    if ($Write) {
        # WriteAllText et non `>` : PowerShell 5.1 ecrit l'operateur `>` en
        # UTF-16LE, ce qui rend le fichier illisible pour kustomize.
        [IO.File]::WriteAllText($path, $new)
    }
}

Write-Host ""
if ($changed -eq 0) {
    Write-Host "Rien a faire." -ForegroundColor Green
}
elseif ($Write) {
    Write-Host "$changed fichier(s) reecrit(s). A COMMITER ET POUSSER :" -ForegroundColor Yellow
    Write-Host "  git add kustomize/overlays/*/ingress.yaml"
    Write-Host "  git commit -m ""chore(ingress): realign hostnames on $ip"""
    Write-Host "  git push"
    Write-Host ""
    Write-Host "ArgoCD lit Git, pas ton disque : sans le push, rien ne change." -ForegroundColor Yellow
}
else {
    Write-Host "$changed fichier(s) a reecrire. Relance avec -Write." -ForegroundColor Yellow
}
