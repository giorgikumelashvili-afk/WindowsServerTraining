param (
    [string]$BaseUrl = "http://localhost",
    [int]$Memory = 3
)

$HealthUrl = "$BaseUrl/cache/get?key=isAlive"

# --- Validation Function ---
function Test-ScriptParameters {
    param (
        [string]$UrlToTest,
        [string]$MemoryToTest # Changed to string to catch suffixes like '2d'
    )

    $isValid = $true

    # 1. Validate URL (Must be valid format and HTTP/HTTPS)
    $uri = $null
    if (-not [System.Uri]::TryCreate($UrlToTest, [System.UriKind]::Absolute, [ref]$uri) -or 
        ($uri.Scheme -ne [System.Uri]::UriSchemeHttp -and $uri.Scheme -ne [System.Uri]::UriSchemeHttps)) {
        Write-Host "  [FAIL] Validation Error: '$UrlToTest' is not a valid HTTP or HTTPS URL." -ForegroundColor Red
        $isValid = $false
    }

    # 2. Validate Memory (Must be ONLY numbers, between 1 and 4)
    if ($MemoryToTest -notmatch '^\d+$') {
        Write-Host "  [FAIL] Validation Error: Memory must be a whole number (e.g., 2). You provided an invalid format: '$MemoryToTest'." -ForegroundColor Red
        $isValid = $false
    } else {
        $memInt = [int]$MemoryToTest
        if ($memInt -lt 1 -or $memInt -gt 4) {
            Write-Host "  [FAIL] Validation Error: Memory must be a number between 1 and 4. You provided: $memInt." -ForegroundColor Red
            $isValid = $false
        }
    }

    if (-not $isValid) {
        Write-Host "Exiting script due to invalid parameters." -ForegroundColor Red
        exit 1
    }
}

Write-Host "Starting Application Validation Test..." -ForegroundColor Cyan
Write-Host "---------------------------------------" -ForegroundColor Cyan

Write-Host "Validating Inputs..."
Test-ScriptParameters -UrlToTest $BaseUrl -MemoryToTest $Memory
Write-Host "  [PASS] Inputs validated successfully.`n" -ForegroundColor Green

# 1 - Restart IIS
Write-Host "1. Restarting IIS..."
iisreset /restart

# 2 - Hit /app/id 3 times, validate each response is different
Write-Host "2. Hitting /app/id 3 times (expecting 3 unique responses)..."
$responsesStep2 = @()
for ($i = 1; $i -le 3; $i++) {
    $response = Invoke-WebRequest -Uri "$BaseUrl/app/id" -UseBasicParsing -ErrorAction Stop
    $content = $response.Content
    Write-Host "   -> Request $i response: $content" -ForegroundColor DarkGray
    $responsesStep2 += $content
}

$uniqueCount2 = ($responsesStep2 | Select-Object -Unique).Count
if ($uniqueCount2 -eq 3) {
    Write-Host "   [PASS] Validated: Received $uniqueCount2 unique responses." -ForegroundColor Green
} else {
    Write-Host "   [FAIL] Expected 3 unique responses, but got $uniqueCount2." -ForegroundColor Red
}

function Test-CacheAndFailover {
    param (
        [string]$BaseUrl,
        [string]$HealthUrl
    )

    # 3 - Hit /cache/set?key=isAlive&value=false (Using POST)
    Write-Host "3. Sending POST request to /cache/set?key=isAlive&value=false..."
    $responseStep3 = Invoke-WebRequest -Uri "$BaseUrl/cache/set?key=isAlive&value=false" -Method Post -UseBasicParsing -ErrorAction Stop
    Write-Host "   -> Response: $($responseStep3.Content)" -ForegroundColor DarkGray

    # 3.5 - Health Check Validation
    Write-Host "3.5 Firing health test 3 times..."
    for ($i = 1; $i -le 3; $i++) {
        try {
            $healthResponse = Invoke-WebRequest -Uri $HealthUrl -UseBasicParsing -TimeoutSec 5 -ErrorAction Stop
            Write-Host "   -> Health request ${i}: [HTTP $($healthResponse.StatusCode)] $($healthResponse.Content)" -ForegroundColor DarkGray
        } catch {
            Write-Host "   -> Health request ${i} failed: $($_.Exception.Message)" -ForegroundColor Red
        }
        Start-Sleep -Seconds 1
    }

    # 3.8 - Smart Polling: Wait for the unhealthy node to drop
    Write-Host "3.8 Waiting for load balancer to drop the unhealthy instance..."
    $maxWaitRetries = 15
    $waitRetryCount = 0
    $nodeDropped = $false

    while (-not $nodeDropped -and $waitRetryCount -lt $maxWaitRetries) {
        $tempResponses = @()
        for ($j = 1; $j -le 3; $j++) {
            $resp = Invoke-WebRequest -Uri "$BaseUrl/app/id" -UseBasicParsing -ErrorAction SilentlyContinue
            if ($resp) { $tempResponses += $resp.Content }
        }
        
        $tempUnique = ($tempResponses | Select-Object -Unique).Count
        if ($tempUnique -eq 2) {
            $nodeDropped = $true
            Write-Host "   [PASS] Node dropped! Only $tempUnique active instances detected." -ForegroundColor Green
        } else {
            $waitRetryCount++
            Write-Host "   -> Still seeing $tempUnique active instances. Waiting 3 seconds... ($waitRetryCount/$maxWaitRetries)" -ForegroundColor DarkGray
            Start-Sleep -Seconds 3
        }
    }

    if (-not $nodeDropped) {
        Write-Host "   [WARNING] The unhealthy node was never dropped from rotation. Step 4 will likely fail." -ForegroundColor Yellow
    }

    # 4 - Hit /app/id 3 times, validate there are only two unique appId
    Write-Host "4. Hitting /app/id 3 times (expecting exactly 2 unique responses)..."
    $responsesStep4 = @()
    for ($i = 1; $i -le 3; $i++) {
        $response = Invoke-WebRequest -Uri "$BaseUrl/app/id" -UseBasicParsing -ErrorAction Stop
        $content = $response.Content
        Write-Host "   -> Request $i response: $content" -ForegroundColor DarkGray
        $responsesStep4 += $content
        
        Start-Sleep -Seconds 1
    }

    $uniqueCount4 = ($responsesStep4 | Select-Object -Unique).Count
    if ($uniqueCount4 -eq 2) {
        Write-Host "   [PASS] Validated: Received exactly $uniqueCount4 unique responses." -ForegroundColor Green
    } else {
        Write-Host "   [FAIL] Expected 2 unique responses, but got $uniqueCount4." -ForegroundColor Red
    }
}

function Test-MemoryLoad {
    param (
        [string]$BaseUrl,
        [int]$MemoryTarget
    )

    # 5 - Hit /memory/fill?upTo=$MemoryTarget
    Write-Host "5. Hitting /memory/fill?upTo=$MemoryTarget..."
    $responseStep5 = Invoke-WebRequest -Uri "$BaseUrl/memory/fill?upTo=$MemoryTarget" -UseBasicParsing -TimeoutSec 120 -ErrorAction Stop
    Write-Host "   -> Response: $($responseStep5.Content)" -ForegroundColor DarkGray
    Start-Sleep -Seconds 3

    # 6 - Validate IIS process has reached target GB of memory
    Write-Host "6. Validating IIS worker process (w3wp) memory usage (Target: $MemoryTarget GB)..."
    $iisProcesses = Get-Process -Name "w3wp" -ErrorAction SilentlyContinue

    if (-not $iisProcesses) {
        Write-Host "   [FAIL] No w3wp (IIS) processes found running." -ForegroundColor Red
    } else {
        $memoryTargetMet = $false
        
        foreach ($proc in $iisProcesses) {
            $memInGB = [math]::Round($proc.WorkingSet64 / 1GB, 2)
            Write-Host "   -> Found w3wp process (ID: $($proc.Id)) utilizing $memInGB GB"
            
            # Dynamically check against the requested Memory Target
            if ($proc.WorkingSet64 -ge ($MemoryTarget * 1GB)) {
                $memoryTargetMet = $true
            }
        }

        if ($memoryTargetMet) {
            Write-Host "   [PASS] Validated: IIS process has reached or exceeded $MemoryTarget GB of memory." -ForegroundColor Green
        } else {
            Write-Host "   [FAIL] No IIS process reached the $MemoryTarget GB memory threshold." -ForegroundColor Red
        }
    }

    # 7 - Hit /memory/release
    Write-Host "7. Hitting /memory/release..."
    $responseStep7 = Invoke-WebRequest -Uri "$BaseUrl/memory/release" -UseBasicParsing -TimeoutSec 120 -ErrorAction Stop
    Write-Host "   -> Response: $($responseStep7.Content)" -ForegroundColor DarkGray
    Start-Sleep -Seconds 3
}

# Execute the functions
Test-CacheAndFailover -BaseUrl $BaseUrl -HealthUrl $HealthUrl
Test-MemoryLoad -BaseUrl $BaseUrl -MemoryTarget $Memory

Write-Host "---------------------------------------" -ForegroundColor Cyan
Write-Host "Testing Complete." -ForegroundColor Cyan