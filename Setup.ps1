param([string]$UserData = $env:APPDATA)
$ErrorActionPreference = 'Stop'
$base = $PSScriptRoot
$server = Join-Path $base 'Server'
$backup = Join-Path $base '.install-backup'

function Backup-File([string]$Path) {
	if (-not (Test-Path -LiteralPath $Path)) { return }
	$sha = [Security.Cryptography.SHA256]::Create()
	try { $id = ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Path)))).Replace('-', '').Substring(0, 16) }
	finally { $sha.Dispose() }
	$destination = Join-Path $backup ($id + '-' + [IO.Path]::GetFileName($Path))
	New-Item -ItemType Directory -Path $backup -Force | Out-Null
	if (-not (Test-Path -LiteralPath $destination)) { Copy-Item -LiteralPath $Path -Destination $destination }
}

function Set-HostsEntry([string]$Path) {
	$bytes = [IO.File]::ReadAllBytes($Path)
	$text = [Text.Encoding]::UTF8.GetString($bytes)
	$entries = @($text -split '\r?\n' | Where-Object { ($_ -split '#', 2)[0] -match '(?i)(?:^|\s)api\.polarclient\.com(?:\s|$)' })
	if ($entries.Count -gt 0) {
		if ($entries.Count -eq 1 -and $entries[0] -match '^\s*127\.0\.0\.1\s+api\.polarclient\.com\s*(?:#.*)?$') { return }
		throw 'api.polarclient.com에 다른 hosts 설정이 있습니다. 기존 설정을 확인한 뒤 다시 실행해 주세요.'
	}
	Backup-File $Path
	$addition = [Text.Encoding]::ASCII.GetBytes("`r`n# Polar local server`r`n127.0.0.1 api.polarclient.com`r`n")
	[IO.File]::WriteAllBytes($Path, [byte[]]($bytes + $addition))
}

function Invoke-Keytool([string]$Exe, [string[]]$Arguments) {
	$ErrorActionPreference = 'Continue'
	& $Exe @Arguments 2>&1 | Out-Null
	return $LASTEXITCODE
}

function Initialize-LocalCertificate([string]$Java) {
	Write-Host '이 PC 전용 인증서와 개인키를 준비하고 있습니다.'
	$generator = Join-Path $server 'tls-setup.jar'
	if (-not (Test-Path -LiteralPath $generator)) { throw '인증서 생성 파일이 없습니다. 배포 폴더를 다시 확인해 주세요.' }
	& $Java '-jar' $generator (Join-Path $server 'tls') 2>&1 | Out-Null
	if ($LASTEXITCODE -ne 0) { throw '이 PC 전용 인증서 생성 또는 검증에 실패했습니다.' }
}

function Install-Certificate([string]$Keytool, [string]$Store) {
	$legacyAlias = 'polar-local-2488eeb2dda8889a'
	if ((Invoke-Keytool $Keytool @('-list', '-alias', $legacyAlias, '-keystore', $Store, '-storepass', 'changeit')) -eq 0) {
		Backup-File $Store
		if ((Invoke-Keytool $Keytool @('-delete', '-alias', $legacyAlias, '-keystore', $Store, '-storepass', 'changeit')) -ne 0) { throw '기존 공용 인증서 제거에 실패했습니다.' }
	}
	$cert = Join-Path $server 'tls\cert.der'
	$expected = (Get-FileHash -LiteralPath $cert -Algorithm SHA256).Hash
	$alias = 'polar-local-' + $expected.Substring(0, 16).ToLowerInvariant()
	$temporary = Join-Path ([IO.Path]::GetTempPath()) ([IO.Path]::GetRandomFileName())
	try {
		$code = Invoke-Keytool $Keytool @('-exportcert', '-alias', $alias, '-keystore', $Store, '-storepass', 'changeit', '-file', $temporary)
		if ($code -ne 0) {
			Backup-File $Store
			$code = Invoke-Keytool $Keytool @('-importcert', '-noprompt', '-trustcacerts', '-alias', $alias, '-file', $cert, '-keystore', $Store, '-storepass', 'changeit')
			if ($code -ne 0) { throw 'Java 인증서 등록에 실패했습니다. 인증서 저장소 암호가 기본값인지 확인해 주세요.' }
			$code = Invoke-Keytool $Keytool @('-exportcert', '-alias', $alias, '-keystore', $Store, '-storepass', 'changeit', '-file', $temporary)
			if ($code -ne 0) { throw 'Java 인증서 확인에 실패했습니다.' }
		}
		if ((Get-FileHash -LiteralPath $temporary -Algorithm SHA256).Hash -ne $expected) { throw '등록된 Java 인증서가 배포본 인증서와 일치하지 않습니다.' }
	}
	finally { if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary } }
}

function Install-Mod([string]$Mods) {
	if (-not (Test-Path -LiteralPath $Mods -PathType Container)) { throw '선택한 mods 폴더가 없습니다.' }
	$source = Join-Path $base 'mods\SilencePolar-3.4.9+mc26.2.jar'
	if (-not (Test-Path -LiteralPath $source)) { throw '배포용 모드 파일이 없습니다. 배포 폴더를 다시 확인해 주세요.' }
	Add-Type -AssemblyName System.IO.Compression.FileSystem
	$archive = [IO.Compression.ZipFile]::OpenRead($source)
	try {
		$entry = $archive.GetEntry('fabric.mod.json')
		if (-not $entry) { throw '배포용 모드 정보를 찾지 못했습니다.' }
		$reader = [IO.StreamReader]::new($entry.Open())
		try { $modId = [string](($reader.ReadToEnd() | ConvertFrom-Json).id) } finally { $reader.Dispose() }
	} finally { $archive.Dispose() }
	if ($modId -ne 'polar-launcher') { throw '배포용 모드 종류가 올바르지 않습니다.' }
	$target = Join-Path $Mods ([IO.Path]::GetFileName($source))
	$sourceHash = (Get-FileHash -LiteralPath $source).Hash
	$previous = @()
	foreach ($file in @(Get-ChildItem -LiteralPath $Mods -Filter '*.jar' -File)) {
		$archive = $null
		try {
			$archive = [IO.Compression.ZipFile]::OpenRead($file.FullName)
			$entry = $archive.GetEntry('fabric.mod.json')
			if (-not $entry) { continue }
			$reader = [IO.StreamReader]::new($entry.Open())
			try { $id = [string](($reader.ReadToEnd() | ConvertFrom-Json).id) } finally { $reader.Dispose() }
			if ($id -eq $modId) { $previous += $file.FullName }
		} catch { continue }
		finally { if ($archive) { $archive.Dispose() } }
	}
	if ((Test-Path -LiteralPath $target) -and $previous -notcontains $target) { $previous += $target }
	foreach ($path in $previous) {
		$hash = (Get-FileHash -LiteralPath $path).Hash
		if ($path -eq $target -and $hash -eq $sourceHash) { continue }
		$directory = Join-Path $backup 'mods'
		New-Item -ItemType Directory -Path $directory -Force | Out-Null
		$saved = Join-Path $directory ($hash.Substring(0, 16) + '-' + [IO.Path]::GetFileName($path))
		if (-not (Test-Path -LiteralPath $saved)) { Copy-Item -LiteralPath $path -Destination $saved }
		if ((Get-FileHash -LiteralPath $saved).Hash -ne $hash) { throw '기존 모드 백업을 확인하지 못했습니다. 설치를 중단합니다.' }
		Remove-Item -LiteralPath $path
	}
	if (-not (Test-Path -LiteralPath $target)) { Copy-Item -LiteralPath $source -Destination $target }
	if ((Get-FileHash -LiteralPath $target).Hash -ne $sourceHash) { throw '설치된 모드 파일을 확인하지 못했습니다.' }
	Write-Host ('모드 설치 완료: ' + $target)
}

function Install-Worlds([string]$World) {
	$source = Join-Path $server 'assets\data\worlds'
	New-Item -ItemType Directory -Path $World -Force | Out-Null
	foreach ($file in @(Get-ChildItem -LiteralPath $source -Filter '*.dat' -File)) {
		$target = Join-Path $World $file.Name
		if ((Test-Path -LiteralPath $target) -and (Get-FileHash -LiteralPath $file.FullName).Hash -eq (Get-FileHash -LiteralPath $target).Hash) { continue }
		Backup-File $target
		Copy-Item -LiteralPath $file.FullName -Destination $target -Force
	}
}

function Install-Loader([string]$Launch) {
	$configuration = Get-Content -LiteralPath (Join-Path $server 'config.json') -Raw | ConvertFrom-Json
	$profile = Get-Content -LiteralPath (Join-Path $server 'startup-profile.private.json') -Raw | ConvertFrom-Json
	if ($profile.loader_fields.Count -lt 9 -or $profile.loader_fields[2] -ne '3.4.9' -or $profile.loader_fields[8] -ne 'release') { throw '3.4.9용 서버 시작 설정이 올바르지 않습니다.' }
	Add-Type -AssemblyName System.IO.Compression.FileSystem
	$source = Join-Path $server 'PolarFabricLoader.jar'
	$archive = [IO.Compression.ZipFile]::OpenRead($source)
	try {
		$entry = $archive.GetEntry('META-INF/polar/manifest.json')
		if (-not $entry) { throw '로더의 배포 정보를 찾지 못했습니다.' }
		$reader = [IO.StreamReader]::new($entry.Open())
		try { $manifest = $reader.ReadToEnd() | ConvertFrom-Json } finally { $reader.Dispose() }
	} finally { $archive.Dispose() }
	if ($manifest.kind -ne 'loader' -or $manifest.version -ne [string]$configuration.loader_version -or $manifest.seq -isnot [int]) { throw '로더 버전과 서버 설정이 일치하지 않습니다.' }
	$loaderHash = (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash.ToLowerInvariant()
	New-Item -ItemType Directory -Path $Launch -Force | Out-Null
	$target = Join-Path $Launch 'PolarFabricLoader.jar'
	if (-not (Test-Path -LiteralPath $target) -or (Get-FileHash -LiteralPath $source).Hash -ne (Get-FileHash -LiteralPath $target).Hash) {
		Backup-File $target
		Copy-Item -LiteralPath $source -Destination $target -Force
	}
	$loaderCache = Join-Path $Launch 'loader'
	New-Item -ItemType Directory -Path $loaderCache -Force | Out-Null
	$cachedLoader = Join-Path $loaderCache ('PolarFabricLoader-' + $loaderHash.Substring(0, 16) + '.jar')
	if (-not (Test-Path -LiteralPath $cachedLoader) -or (Get-FileHash -LiteralPath $cachedLoader).Hash -ine $loaderHash) {
		Backup-File $cachedLoader
		Copy-Item -LiteralPath $source -Destination $cachedLoader -Force
	}
	$current = Join-Path $loaderCache 'current'
	Backup-File $current
	[IO.File]::WriteAllText($current, ([string]$manifest.version + "`n" + $loaderHash + "`n" + [string]$manifest.seq), [Text.UTF8Encoding]::new($false))
	$clientCache = Join-Path $Launch 'cache'
	New-Item -ItemType Directory -Path $clientCache -Force | Out-Null
	$clientSource = Join-Path $server 'PolarClient.jar'
	$clientTarget = Join-Path $clientCache 'PolarClient-3.4.9.jar'
	if (-not (Test-Path -LiteralPath $clientTarget) -or (Get-FileHash -LiteralPath $clientTarget).Hash -ne (Get-FileHash -LiteralPath $clientSource).Hash) {
		Backup-File $clientTarget
		Copy-Item -LiteralPath $clientSource -Destination $clientTarget -Force
	}
	foreach ($item in @(@('fabric-loader.version', [string]$manifest.version), @('channel.txt', [string]$profile.loader_fields[8]))) {
		$path = Join-Path $Launch $item[0]
		Backup-File $path
		[IO.File]::WriteAllText($path, $item[1], [Text.Encoding]::ASCII)
	}
}

try {
	$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
	if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
		$arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-File', ('"' + $PSCommandPath + '"'), '-UserData', ('"' + $UserData + '"'))
		$process = Start-Process powershell.exe -Verb RunAs -ArgumentList $arguments -Wait -PassThru
		if ($process.ExitCode -ne 0) {
			$errorLog = Join-Path $base 'Install-Error.log'
			if (Test-Path -LiteralPath $errorLog) { Write-Host (Get-Content -LiteralPath $errorLog -Raw -Encoding UTF8) -ForegroundColor Red }
			Write-Host ('설치에 실패했습니다. 오류 기록: ' + $errorLog) -ForegroundColor Red
		}
		exit $process.ExitCode
	}
	Write-Host 'Polar 로컬 서버 설치 (Windows x64 / Fabric 26.2 / Java 25)'
	Write-Host '게임과 런처를 종료한 상태에서 진행해 주세요.'
	$candidates = @()
	foreach ($runtime in @((Join-Path $UserData 'PrismLauncher\java'), (Join-Path $UserData '.minecraft\runtime'))) {
		if (-not (Test-Path -LiteralPath $runtime)) { continue }
		foreach ($file in @(Get-ChildItem -LiteralPath $runtime -Filter release -File -Recurse -ErrorAction SilentlyContinue)) {
			$runtimeHome = $file.DirectoryName
			if ((Get-Content -LiteralPath $file.FullName -Raw) -match '(?m)^JAVA_VERSION="25(?:\.|\+|\")' -and (Test-Path -LiteralPath (Join-Path $runtimeHome 'bin\java.exe'))) { $candidates += $runtimeHome }
		}
	}
	$candidates = @($candidates | Select-Object -Unique)
	if ($candidates.Count -eq 1) { $javaHome = $candidates[0] }
	else {
		Add-Type -AssemblyName System.Windows.Forms
		$dialog = New-Object System.Windows.Forms.OpenFileDialog
		$dialog.Title = '게임 런처에서 사용하는 Java 25의 java.exe를 선택해 주세요'
		$dialog.Filter = 'Java 실행 파일|java.exe;javaw.exe'
		if ($candidates.Count -gt 0) { $dialog.InitialDirectory = Join-Path $candidates[0] 'bin' }
		if ($dialog.ShowDialog() -ne 'OK') { throw 'Java 선택을 취소했습니다. 설치를 중단합니다.' }
		$javaHome = Split-Path -Parent (Split-Path -Parent $dialog.FileName)
	}
	$release = Join-Path $javaHome 'release'
	if (-not (Test-Path -LiteralPath $release) -or (Get-Content -LiteralPath $release -Raw) -notmatch '(?m)^JAVA_VERSION="25(?:\.|\+|\")') { throw '게임에서 사용하는 Java 25를 선택해 주세요.' }
	if (-not (Test-Path -LiteralPath (Join-Path $javaHome 'bin\keytool.exe'))) { throw '선택한 Java에 keytool.exe가 없습니다.' }
	Write-Host ('선택한 Java: ' + $javaHome)
	Add-Type -AssemblyName System.Windows.Forms
	$dialog = New-Object System.Windows.Forms.OpenFileDialog
	try {
		$dialog.Title = '모드를 설치할 게임 인스턴스 또는 mods 폴더를 선택해 주세요.'
		$dialog.ValidateNames = $false
		$dialog.CheckFileExists = $false
		$dialog.CheckPathExists = $true
		$dialog.FileName = 'Folder Selection'
		$instances = Join-Path $UserData 'PrismLauncher\instances'
		if (Test-Path -LiteralPath $instances) { $dialog.InitialDirectory = $instances }
		if ($dialog.ShowDialog() -ne 'OK') { throw '모드 설치 폴더 선택을 취소했습니다.' }
		$modsFolder = Split-Path -LiteralPath $dialog.FileName -Parent
		if ([IO.Path]::GetFileName($modsFolder) -ine 'mods') { $modsFolder = Join-Path $modsFolder 'mods' }
		if (-not (Test-Path -LiteralPath $modsFolder -PathType Container)) { throw '게임 인스턴스의 mods 폴더를 선택해 주세요.' }
	} finally { $dialog.Dispose() }
	Initialize-LocalCertificate (Join-Path $javaHome 'bin\java.exe')
	Install-Certificate (Join-Path $javaHome 'bin\keytool.exe') (Join-Path $javaHome 'lib\security\cacerts')
	Install-Loader (Join-Path $UserData '.minecraft\PolarClient\launch')
	Install-Worlds (Join-Path $UserData '.minecraft\PolarClient\world')
	Install-Mod $modsFolder
	Set-HostsEntry (Join-Path $env:SystemRoot 'System32\drivers\etc\hosts')
	Clear-DnsClientCache
	Write-Host '설치가 완료되었습니다. GUI에서 서버를 시작한 뒤 게임을 실행해 주세요.'
	Write-Host '런처에서도 선택한 Java를 사용해 주세요. 변경 전 파일은 .install-backup에 보관됩니다.'
	exit 0
}
catch {
	$errorLog = Join-Path $base 'Install-Error.log'
	$details = $_.Exception.Message + [Environment]::NewLine + $_.ScriptStackTrace
	[IO.File]::WriteAllText($errorLog, $details, [Text.Encoding]::UTF8)
	Write-Host ('설치 오류: ' + $_.Exception.Message) -ForegroundColor Red
	Write-Host '일부 설정은 이미 적용되었을 수 있습니다. 변경 전 파일은 .install-backup에서 확인해 주세요.'
	exit 1
}
