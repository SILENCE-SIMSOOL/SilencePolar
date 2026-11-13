param([ValidateSet('On', 'Off')][string]$Mode)
$ErrorActionPreference = 'Stop'

function Set-PolarHostsText([string]$Text, [string]$Selection) {
	$domain = '(?i)(?<!\S)api\.polarclient\.com(?!\S)'
	$clean = [regex]::Replace($Text, '[^\r\n]+(?:\r\n|\n|$)', {
		param($match)
		$line = $match.Value.TrimEnd("`r", "`n")
		if ($line -eq '# Polar local server') { return '' }
		$parts = $line -split '#', 2
		if ($parts[0] -notmatch $domain) { return $match.Value }
		$active = [regex]::Replace($parts[0], $domain, '')
		$tokens = @($active.Trim() -split '\s+' | Where-Object { $_ })
		$ending = $match.Value.Substring($line.Length)
		if ($tokens.Count -lt 2) {
			if ($parts.Count -eq 2) { return '#' + $parts[1] + $ending }
			return ''
		}
		if ($parts.Count -eq 2) { return $active + '#' + $parts[1] + $ending }
		return $active + $ending
	})
	if ($Selection -eq 'Off') { return $clean }
	if ($clean.Length -gt 0 -and -not $clean.EndsWith("`n")) { $clean += "`r`n" }
	return $clean + "# Polar local server`r`n127.0.0.1 api.polarclient.com`r`n"
}

try {
	if (-not $Mode) {
		Write-Host '1. ON  - Local server (127.0.0.1)'
		Write-Host '2. OFF - Original server (normal DNS)'
		Write-Host '0. Cancel'
		switch (Read-Host 'Select') {
			'1' { $Mode = 'On' }
			'2' { $Mode = 'Off' }
			'0' { exit 0 }
			default { throw 'Select 1, 2, or 0.' }
		}
	}
	$principal = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
	if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
		$arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $PSCommandPath + '"'), '-Mode', $Mode)
		$process = Start-Process powershell.exe -Verb RunAs -ArgumentList $arguments -Wait -PassThru
		exit $process.ExitCode
	}
	$target = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
	$encoding = [Text.Encoding]::GetEncoding(28591)
	$bytes = [IO.File]::ReadAllBytes($target)
	$text = $encoding.GetString($bytes)
	$updated = Set-PolarHostsText $text $Mode
	if ($updated -cne $text) {
		$backup = Join-Path $PSScriptRoot ('.hosts-backup-' + [DateTime]::Now.ToString('yyyyMMdd-HHmmss-fffffff'))
		Copy-Item -LiteralPath $target -Destination $backup
		[IO.File]::WriteAllBytes($target, $encoding.GetBytes($updated))
		if ($encoding.GetString([IO.File]::ReadAllBytes($target)) -cne $updated) { throw 'Hosts verification failed.' }
		Write-Host ('Backup: ' + $backup)
	}
	Clear-DnsClientCache
	Write-Host ('Polar hosts: ' + $Mode)
	Write-Host 'Restart the game to reconnect.'
	exit 0
}
catch {
	Write-Host $_.Exception.Message -ForegroundColor Red
	exit 1
}