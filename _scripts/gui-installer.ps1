#Requires -Version 5.0

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$appRoot = Split-Path -Parent $PSScriptRoot
$script:step = 1
$script:data = @{}

function Generate-SecurePassword {
    # Uses a cryptographic RNG (System.Random is NOT safe for secrets - it's
    # a seeded PRNG, not suitable for passwords/tokens/keys).
    param([int]$Length = 32)
    $chars = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!@#$%^&*'
    $bytes = [byte[]]::new($Length)
    [System.Security.Cryptography.RandomNumberGenerator]::Fill($bytes)
    $password = -join ($bytes | ForEach-Object { $chars[$_ % $chars.Length] })
    return $password
}

function Get-CaddyPasswordHash {
    # Shells out to the same Caddy image the stack itself runs, so the
    # hash format always matches what Caddy's own basic_auth directive
    # expects (bcrypt) - never hand-rolled or approximated. Docker is
    # already a hard prerequisite for this entire repo, so this adds no
    # new dependency. Passed as a real argument, not string-interpolated
    # into a command line, so special characters in the password (this
    # repo's generated passwords include !@#$%^&*) can't be misread as
    # shell syntax.
    param([Parameter(Mandatory=$true)][string]$PlainSecret)
    $hash = & docker run --rm caddy:2.11.4 caddy hash-password --plaintext $PlainSecret
    return ($hash | Select-Object -Last 1).Trim()
}

function Validate-Email { param([string]$e) return $e -match '^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$' }
function Validate-Domain { param([string]$d) return $d -match '^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$' }
function Show-Error { param([string]$m) [System.Windows.Forms.MessageBox]::Show($m, "Error", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null }
function Show-Success { param([string]$m) [System.Windows.Forms.MessageBox]::Show($m, "Success", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null }

function Create-Form {
    $f = New-Object System.Windows.Forms.Form
    $f.Text = "Docker Home Lab - Configuration Wizard"
    $f.Width = 650
    $f.Height = 620
    $f.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
    $f.BackColor = [System.Drawing.Color]::White
    $f.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
    $f.MaximizeBox = $false
    $f.MinimizeBox = $false
    return $f
}

function Show-Step1 {
    param($form)
    
    $form.Controls.Clear()
    
    # Title
    $titleLabel = New-Object System.Windows.Forms.Label
    $titleLabel.Text = "Step 1 of 5: Basic Configuration"
    $titleLabel.Top = 20
    $titleLabel.Left = 20
    $titleLabel.Width = 600
    $titleLabel.Height = 30
    $titleLabel.Font = New-Object System.Drawing.Font("Segoe UI", 13, [System.Drawing.FontStyle]::Bold)
    $form.Controls.Add($titleLabel)
    
    # Description
    $descLabel = New-Object System.Windows.Forms.Label
    $descLabel.Text = "Enter your domain, email, and Cloudflare credentials"
    $descLabel.Top = 55
    $descLabel.Left = 20
    $descLabel.Width = 600
    $descLabel.Height = 30
    $descLabel.Font = New-Object System.Drawing.Font("Segoe UI", 9)
    $descLabel.ForeColor = [System.Drawing.Color]::Gray
    $form.Controls.Add($descLabel)
    
    # Domain Label
    $domainLabelCtrl = New-Object System.Windows.Forms.Label
    $domainLabelCtrl.Text = "Domain Name (e.g., yourdomain.com)"
    $domainLabelCtrl.Top = 100
    $domainLabelCtrl.Left = 20
    $domainLabelCtrl.Width = 600
    $domainLabelCtrl.Height = 20
    $domainLabelCtrl.Font = New-Object System.Drawing.Font("Segoe UI", 10)
    $form.Controls.Add($domainLabelCtrl)
    
    # Domain TextBox
    $domainBox = New-Object System.Windows.Forms.TextBox
    $domainBox.Top = 120
    $domainBox.Left = 20
    $domainBox.Width = 600
    $domainBox.Height = 30
    $domainBox.Font = New-Object System.Drawing.Font("Consolas", 10)
    $domainBox.Text = "yourdomain.com"
    $form.Controls.Add($domainBox)
    
    # Email Label
    $emailLabelCtrl = New-Object System.Windows.Forms.Label
    $emailLabelCtrl.Text = "Email for SSL (e.g., admin@yourdomain.com)"
    $emailLabelCtrl.Top = 160
    $emailLabelCtrl.Left = 20
    $emailLabelCtrl.Width = 600
    $emailLabelCtrl.Height = 20
    $emailLabelCtrl.Font = New-Object System.Drawing.Font("Segoe UI", 10)
    $form.Controls.Add($emailLabelCtrl)
    
    # Email TextBox
    $emailBox = New-Object System.Windows.Forms.TextBox
    $emailBox.Top = 180
    $emailBox.Left = 20
    $emailBox.Width = 600
    $emailBox.Height = 30
    $emailBox.Font = New-Object System.Drawing.Font("Consolas", 10)
    $emailBox.Text = "admin@yourdomain.com"
    $form.Controls.Add($emailBox)
    
    # Timezone Label
    $tzLabelCtrl = New-Object System.Windows.Forms.Label
    $tzLabelCtrl.Text = "Timezone"
    $tzLabelCtrl.Top = 220
    $tzLabelCtrl.Left = 20
    $tzLabelCtrl.Width = 600
    $tzLabelCtrl.Height = 20
    $tzLabelCtrl.Font = New-Object System.Drawing.Font("Segoe UI", 10)
    $form.Controls.Add($tzLabelCtrl)
    
    # Timezone ComboBox
    $tzBox = New-Object System.Windows.Forms.ComboBox
    $tzBox.Top = 240
    $tzBox.Left = 20
    $tzBox.Width = 600
    $tzBox.Height = 30
    $tzBox.Font = New-Object System.Drawing.Font("Segoe UI", 10)
    $tzBox.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
    @("UTC", "US/Eastern", "US/Central", "US/Mountain", "US/Pacific", "Europe/London", "Europe/Paris", "Australia/Sydney") | ForEach-Object { $tzBox.Items.Add($_) | Out-Null }
    $tzBox.SelectedIndex = 0
    $form.Controls.Add($tzBox)

    # Cloudflare info label
    $cfInfoLabel = New-Object System.Windows.Forms.Label
    $cfInfoLabel.Text = "Cloudflare Tunnel (for remote access behind CGNAT) - see SETUP.md for how to create these"
    $cfInfoLabel.Top = 280
    $cfInfoLabel.Left = 20
    $cfInfoLabel.Width = 600
    $cfInfoLabel.Height = 20
    $cfInfoLabel.Font = New-Object System.Drawing.Font("Segoe UI", 8, [System.Drawing.FontStyle]::Italic)
    $cfInfoLabel.ForeColor = [System.Drawing.Color]::Blue
    $form.Controls.Add($cfInfoLabel)

    # Cloudflare API Token Label
    $cfApiLabelCtrl = New-Object System.Windows.Forms.Label
    $cfApiLabelCtrl.Text = "Cloudflare API Token (Zone:DNS:Edit, scoped to your domain)"
    $cfApiLabelCtrl.Top = 305
    $cfApiLabelCtrl.Left = 20
    $cfApiLabelCtrl.Width = 600
    $cfApiLabelCtrl.Height = 20
    $cfApiLabelCtrl.Font = New-Object System.Drawing.Font("Segoe UI", 10)
    $form.Controls.Add($cfApiLabelCtrl)

    # Cloudflare API Token TextBox
    $cfApiBox = New-Object System.Windows.Forms.TextBox
    $cfApiBox.Top = 325
    $cfApiBox.Left = 20
    $cfApiBox.Width = 600
    $cfApiBox.Height = 30
    $cfApiBox.Font = New-Object System.Drawing.Font("Consolas", 10)
    $cfApiBox.UseSystemPasswordChar = $true
    $form.Controls.Add($cfApiBox)

    # Cloudflare Tunnel Token Label
    $cfTunnelLabelCtrl = New-Object System.Windows.Forms.Label
    $cfTunnelLabelCtrl.Text = "Cloudflare Tunnel Token (Zero Trust -> Networks -> Tunnels)"
    $cfTunnelLabelCtrl.Top = 365
    $cfTunnelLabelCtrl.Left = 20
    $cfTunnelLabelCtrl.Width = 600
    $cfTunnelLabelCtrl.Height = 20
    $cfTunnelLabelCtrl.Font = New-Object System.Drawing.Font("Segoe UI", 10)
    $form.Controls.Add($cfTunnelLabelCtrl)

    # Cloudflare Tunnel Token TextBox
    $cfTunnelBox = New-Object System.Windows.Forms.TextBox
    $cfTunnelBox.Top = 385
    $cfTunnelBox.Left = 20
    $cfTunnelBox.Width = 600
    $cfTunnelBox.Height = 30
    $cfTunnelBox.Font = New-Object System.Drawing.Font("Consolas", 10)
    $cfTunnelBox.UseSystemPasswordChar = $true
    $form.Controls.Add($cfTunnelBox)

    # Mail Domain Label
    $mailDomainLabelCtrl = New-Object System.Windows.Forms.Label
    $mailDomainLabelCtrl.Text = "Mail Domain (optional - only if Mailu needs a DIFFERENT domain than above, e.g. main domain already has real email elsewhere)"
    $mailDomainLabelCtrl.Top = 425
    $mailDomainLabelCtrl.Left = 20
    $mailDomainLabelCtrl.Width = 600
    $mailDomainLabelCtrl.Height = 20
    $mailDomainLabelCtrl.Font = New-Object System.Drawing.Font("Segoe UI", 8)
    $form.Controls.Add($mailDomainLabelCtrl)

    # Mail Domain TextBox
    $mailDomainBox = New-Object System.Windows.Forms.TextBox
    $mailDomainBox.Top = 445
    $mailDomainBox.Left = 20
    $mailDomainBox.Width = 600
    $mailDomainBox.Height = 30
    $mailDomainBox.Font = New-Object System.Drawing.Font("Consolas", 10)
    $form.Controls.Add($mailDomainBox)

    # Back Button
    $backBtn = New-Object System.Windows.Forms.Button
    $backBtn.Text = "← Back"
    $backBtn.Top = 530
    $backBtn.Left = 470
    $backBtn.Width = 80
    $backBtn.Height = 35
    $backBtn.Enabled = $false
    $backBtn.Font = New-Object System.Drawing.Font("Segoe UI", 10)
    $form.Controls.Add($backBtn)
    
    # Next Button
    $nextBtn = New-Object System.Windows.Forms.Button
    $nextBtn.Text = "Next →"
    $nextBtn.Top = 530
    $nextBtn.Left = 560
    $nextBtn.Width = 80
    $nextBtn.Height = 35
    $nextBtn.Font = New-Object System.Drawing.Font("Segoe UI", 10)
    $nextBtn.BackColor = [System.Drawing.Color]::LightBlue
    $form.Controls.Add($nextBtn)
    
    # Progress
    $progLabel = New-Object System.Windows.Forms.Label
    $progLabel.Text = "Step 1 of 5"
    $progLabel.Top = 535
    $progLabel.Left = 20
    $progLabel.Width = 200
    $progLabel.Height = 25
    $progLabel.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
    $form.Controls.Add($progLabel)
    
    $nextBtn.Add_Click({
        $domain = $domainBox.Text.Trim()
        $email = $emailBox.Text.Trim()
        $cfApiToken = $cfApiBox.Text.Trim()
        $cfTunnelToken = $cfTunnelBox.Text.Trim()
        $mailDomain = $mailDomainBox.Text.Trim()

        if ([string]::IsNullOrEmpty($domain)) { Show-Error "Domain is required"; return }
        if (-not (Validate-Domain $domain)) { Show-Error "Invalid domain format"; return }
        if ([string]::IsNullOrEmpty($email)) { Show-Error "Email is required"; return }
        if (-not (Validate-Email $email)) { Show-Error "Invalid email format"; return }
        # Required, not optional: Caddy now issues every certificate via
        # Cloudflare DNS-01 (see caddy/Caddyfile) rather than the old
        # inbound-port challenge, so there's no working fallback without
        # this - leaving it blank would mean Caddy can't get a single
        # certificate for anything.
        if ([string]::IsNullOrEmpty($cfApiToken)) { Show-Error "Cloudflare API Token is required - see SETUP.md"; return }
        if ([string]::IsNullOrEmpty($cfTunnelToken)) { Show-Error "Cloudflare Tunnel Token is required - see SETUP.md"; return }
        # Mail Domain is the one genuinely optional field on this step -
        # only validate its format if something was actually typed in.
        if (-not [string]::IsNullOrEmpty($mailDomain) -and -not (Validate-Domain $mailDomain)) { Show-Error "Invalid Mail Domain format"; return }

        $script:data.Domain = $domain
        $script:data.Email = $email
        $script:data.Timezone = $tzBox.SelectedItem
        $script:data.CloudflareApiToken = $cfApiToken
        $script:data.CloudflareTunnelToken = $cfTunnelToken
        # Falls back to the main domain when left blank - see caddy/.env's
        # MAIL_DOMAIN and email-stack/.env's DOMAIN.
        $script:data.MailDomain = if ([string]::IsNullOrEmpty($mailDomain)) { $domain } else { $mailDomain }

        $script:step = 2
        Show-Step2 $form
    })
}

function Show-Step2 {
    param($form)
    
    $form.Controls.Clear()
    
    $titleLabel = New-Object System.Windows.Forms.Label
    $titleLabel.Text = "Step 2 of 5: ProtonVPN Configuration"
    $titleLabel.Top = 20
    $titleLabel.Left = 20
    $titleLabel.Width = 600
    $titleLabel.Height = 30
    $titleLabel.Font = New-Object System.Drawing.Font("Segoe UI", 13, [System.Drawing.FontStyle]::Bold)
    $form.Controls.Add($titleLabel)
    
    $descLabel = New-Object System.Windows.Forms.Label
    $descLabel.Text = "Enter your ProtonVPN OpenVPN credentials"
    $descLabel.Top = 55
    $descLabel.Left = 20
    $descLabel.Width = 600
    $descLabel.Height = 30
    $descLabel.Font = New-Object System.Drawing.Font("Segoe UI", 9)
    $descLabel.ForeColor = [System.Drawing.Color]::Gray
    $form.Controls.Add($descLabel)
    
    $infoLabel = New-Object System.Windows.Forms.Label
    $infoLabel.Text = "Get from: https://account.protonvpn.com/account#downloads (OpenVPN Credentials)"
    $infoLabel.Top = 100
    $infoLabel.Left = 20
    $infoLabel.Width = 600
    $infoLabel.Height = 40
    $infoLabel.Font = New-Object System.Drawing.Font("Segoe UI", 8, [System.Drawing.FontStyle]::Italic)
    $infoLabel.ForeColor = [System.Drawing.Color]::Blue
    $form.Controls.Add($infoLabel)
    
    # ProtonVPN Username Label
    $userLabelCtrl = New-Object System.Windows.Forms.Label
    $userLabelCtrl.Text = "ProtonVPN Username (username+sXXXXXX@protonvpn.com)"
    $userLabelCtrl.Top = 150
    $userLabelCtrl.Left = 20
    $userLabelCtrl.Width = 600
    $userLabelCtrl.Height = 20
    $userLabelCtrl.Font = New-Object System.Drawing.Font("Segoe UI", 10)
    $form.Controls.Add($userLabelCtrl)
    
    # ProtonVPN Username TextBox
    $userBox = New-Object System.Windows.Forms.TextBox
    $userBox.Top = 170
    $userBox.Left = 20
    $userBox.Width = 600
    $userBox.Height = 30
    $userBox.Font = New-Object System.Drawing.Font("Consolas", 10)
    $form.Controls.Add($userBox)
    
    # ProtonVPN Password Label
    $passLabelCtrl = New-Object System.Windows.Forms.Label
    $passLabelCtrl.Text = "ProtonVPN Password"
    $passLabelCtrl.Top = 210
    $passLabelCtrl.Left = 20
    $passLabelCtrl.Width = 600
    $passLabelCtrl.Height = 20
    $passLabelCtrl.Font = New-Object System.Drawing.Font("Segoe UI", 10)
    $form.Controls.Add($passLabelCtrl)
    
    # ProtonVPN Password TextBox
    $passBox = New-Object System.Windows.Forms.TextBox
    $passBox.Top = 230
    $passBox.Left = 20
    $passBox.Width = 600
    $passBox.Height = 30
    $passBox.Font = New-Object System.Drawing.Font("Consolas", 10)
    $passBox.UseSystemPasswordChar = $true
    $form.Controls.Add($passBox)
    
    # Country Label
    $countryLabelCtrl = New-Object System.Windows.Forms.Label
    $countryLabelCtrl.Text = "VPN Country"
    $countryLabelCtrl.Top = 270
    $countryLabelCtrl.Left = 20
    $countryLabelCtrl.Width = 600
    $countryLabelCtrl.Height = 20
    $countryLabelCtrl.Font = New-Object System.Drawing.Font("Segoe UI", 10)
    $form.Controls.Add($countryLabelCtrl)
    
    # Country ComboBox
    $countryBox = New-Object System.Windows.Forms.ComboBox
    $countryBox.Top = 290
    $countryBox.Left = 20
    $countryBox.Width = 600
    $countryBox.Height = 30
    $countryBox.Font = New-Object System.Drawing.Font("Segoe UI", 10)
    $countryBox.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
    @("US", "UK", "CA", "AU", "DE", "NL", "FR", "CH") | ForEach-Object { $countryBox.Items.Add($_) | Out-Null }
    $countryBox.SelectedIndex = 0
    $form.Controls.Add($countryBox)
    
    # Back Button
    $backBtn = New-Object System.Windows.Forms.Button
    $backBtn.Text = "← Back"
    $backBtn.Top = 530
    $backBtn.Left = 470
    $backBtn.Width = 80
    $backBtn.Height = 35
    $backBtn.Font = New-Object System.Drawing.Font("Segoe UI", 10)
    $backBtn.Add_Click({ $script:step = 1; Show-Step1 $form })
    $form.Controls.Add($backBtn)
    
    # Next Button
    $nextBtn = New-Object System.Windows.Forms.Button
    $nextBtn.Text = "Next →"
    $nextBtn.Top = 530
    $nextBtn.Left = 560
    $nextBtn.Width = 80
    $nextBtn.Height = 35
    $nextBtn.Font = New-Object System.Drawing.Font("Segoe UI", 10)
    $nextBtn.BackColor = [System.Drawing.Color]::LightBlue
    $nextBtn.Add_Click({
        $user = $userBox.Text.Trim()
        $pass = $passBox.Text.Trim()
        
        if ([string]::IsNullOrEmpty($user)) { Show-Error "ProtonVPN Username is required"; return }
        if ([string]::IsNullOrEmpty($pass)) { Show-Error "ProtonVPN Password is required"; return }
        
        $script:data.ProtonUsername = $user
        $script:data.ProtonPassword = $pass
        $script:data.ProtonCountry = $countryBox.SelectedItem
        
        $script:step = 3
        Show-Step3 $form
    })
    $form.Controls.Add($nextBtn)
    
    # Progress
    $progLabel = New-Object System.Windows.Forms.Label
    $progLabel.Text = "Step 2 of 5"
    $progLabel.Top = 535
    $progLabel.Left = 20
    $progLabel.Width = 200
    $progLabel.Height = 25
    $progLabel.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
    $form.Controls.Add($progLabel)
}

function Show-Step3 {
    param($form)
    
    $form.Controls.Clear()
    
    $titleLabel = New-Object System.Windows.Forms.Label
    $titleLabel.Text = "Step 3 of 5: Plex Token"
    $titleLabel.Top = 20
    $titleLabel.Left = 20
    $titleLabel.Width = 600
    $titleLabel.Height = 30
    $titleLabel.Font = New-Object System.Drawing.Font("Segoe UI", 13, [System.Drawing.FontStyle]::Bold)
    $form.Controls.Add($titleLabel)
    
    $descLabel = New-Object System.Windows.Forms.Label
    $descLabel.Text = "Get your Plex claim token (expires in 4 minutes!)"
    $descLabel.Top = 55
    $descLabel.Left = 20
    $descLabel.Width = 600
    $descLabel.Height = 30
    $descLabel.Font = New-Object System.Drawing.Font("Segoe UI", 9)
    $descLabel.ForeColor = [System.Drawing.Color]::Gray
    $form.Controls.Add($descLabel)
    
    $warnLabel = New-Object System.Windows.Forms.Label
    # Plain WARNING: prefix, not the emoji - a compound/supplementary-plane
    # emoji like this one has no glyph in Segoe UI's default (non-emoji)
    # rendering here and shows as a tofu box instead - confirmed live.
    $warnLabel.Text = "WARNING: Token expires in 4 minutes! Go to https://plex.tv/claim, copy token (starts with 'claim-'), paste here immediately."
    $warnLabel.Top = 100
    $warnLabel.Left = 20
    $warnLabel.Width = 600
    $warnLabel.Height = 50
    $warnLabel.Font = New-Object System.Drawing.Font("Segoe UI", 8, [System.Drawing.FontStyle]::Italic)
    $warnLabel.ForeColor = [System.Drawing.Color]::Red
    $form.Controls.Add($warnLabel)
    
    # Token Label
    $tokenLabelCtrl = New-Object System.Windows.Forms.Label
    $tokenLabelCtrl.Text = "Plex Claim Token"
    $tokenLabelCtrl.Top = 160
    $tokenLabelCtrl.Left = 20
    $tokenLabelCtrl.Width = 600
    $tokenLabelCtrl.Height = 20
    $tokenLabelCtrl.Font = New-Object System.Drawing.Font("Segoe UI", 10)
    $form.Controls.Add($tokenLabelCtrl)
    
    # Token TextBox
    $tokenBox = New-Object System.Windows.Forms.TextBox
    $tokenBox.Top = 180
    $tokenBox.Left = 20
    $tokenBox.Width = 600
    $tokenBox.Height = 30
    $tokenBox.Font = New-Object System.Drawing.Font("Consolas", 10)
    $form.Controls.Add($tokenBox)
    
    # Back Button
    $backBtn = New-Object System.Windows.Forms.Button
    $backBtn.Text = "← Back"
    $backBtn.Top = 530
    $backBtn.Left = 470
    $backBtn.Width = 80
    $backBtn.Height = 35
    $backBtn.Font = New-Object System.Drawing.Font("Segoe UI", 10)
    $backBtn.Add_Click({ $script:step = 2; Show-Step2 $form })
    $form.Controls.Add($backBtn)
    
    # Next Button
    $nextBtn = New-Object System.Windows.Forms.Button
    $nextBtn.Text = "Next →"
    $nextBtn.Top = 530
    $nextBtn.Left = 560
    $nextBtn.Width = 80
    $nextBtn.Height = 35
    $nextBtn.Font = New-Object System.Drawing.Font("Segoe UI", 10)
    $nextBtn.BackColor = [System.Drawing.Color]::LightBlue
    $nextBtn.Add_Click({
        $token = $tokenBox.Text.Trim()
        if ([string]::IsNullOrEmpty($token)) { Show-Error "Plex token required"; return }
        if (-not $token.StartsWith("claim-")) { Show-Error "Token should start with 'claim-'"; return }
        
        $script:data.PlexToken = $token
        $script:data.PlexDomain = "plex.$($script:data.Domain)"
        $script:data.JellyfinDomain = "jellyfin.$($script:data.Domain)"
        
        $script:step = 4
        Show-Step4 $form
    })
    $form.Controls.Add($nextBtn)
    
    # Progress
    $progLabel = New-Object System.Windows.Forms.Label
    $progLabel.Text = "Step 3 of 5"
    $progLabel.Top = 535
    $progLabel.Left = 20
    $progLabel.Width = 200
    $progLabel.Height = 25
    $progLabel.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
    $form.Controls.Add($progLabel)
}

function Show-Step4 {
    param($form)
    
    $form.Controls.Clear()
    
    $titleLabel = New-Object System.Windows.Forms.Label
    $titleLabel.Text = "Step 4 of 5: Generate Passwords"
    $titleLabel.Top = 20
    $titleLabel.Left = 20
    $titleLabel.Width = 600
    $titleLabel.Height = 30
    $titleLabel.Font = New-Object System.Drawing.Font("Segoe UI", 13, [System.Drawing.FontStyle]::Bold)
    $form.Controls.Add($titleLabel)
    
    $descLabel = New-Object System.Windows.Forms.Label
    $descLabel.Text = "Click button to generate secure passwords"
    $descLabel.Top = 55
    $descLabel.Left = 20
    $descLabel.Width = 600
    $descLabel.Height = 30
    $descLabel.Font = New-Object System.Drawing.Font("Segoe UI", 9)
    $descLabel.ForeColor = [System.Drawing.Color]::Gray
    $form.Controls.Add($descLabel)
    
    # Generate Button
    # Plain text, not a lock emoji - confirmed live it renders as an empty
    # tofu box in Segoe UI's default (non-emoji) rendering here.
    $genBtn = New-Object System.Windows.Forms.Button
    $genBtn.Text = "Generate Passwords"
    $genBtn.Top = 120
    $genBtn.Left = 125
    $genBtn.Width = 400
    $genBtn.Height = 50
    $genBtn.Font = New-Object System.Drawing.Font("Segoe UI", 11, [System.Drawing.FontStyle]::Bold)
    $genBtn.BackColor = [System.Drawing.Color]::LightGreen
    $form.Controls.Add($genBtn)
    
    # Status Label
    $statusLabel = New-Object System.Windows.Forms.Label
    $statusLabel.Text = "Ready to generate"
    $statusLabel.Top = 190
    $statusLabel.Left = 20
    $statusLabel.Width = 600
    $statusLabel.Height = 150
    $statusLabel.Font = New-Object System.Drawing.Font("Segoe UI", 9)
    $form.Controls.Add($statusLabel)
    
    # Back Button
    $backBtn = New-Object System.Windows.Forms.Button
    $backBtn.Text = "← Back"
    $backBtn.Top = 530
    $backBtn.Left = 470
    $backBtn.Width = 80
    $backBtn.Height = 35
    $backBtn.Font = New-Object System.Drawing.Font("Segoe UI", 10)
    $backBtn.Add_Click({ $script:step = 3; Show-Step3 $form })
    $form.Controls.Add($backBtn)
    
    # Next Button
    $nextBtn = New-Object System.Windows.Forms.Button
    $nextBtn.Text = "Next →"
    $nextBtn.Top = 530
    $nextBtn.Left = 560
    $nextBtn.Width = 80
    $nextBtn.Height = 35
    $nextBtn.Font = New-Object System.Drawing.Font("Segoe UI", 10)
    $nextBtn.BackColor = [System.Drawing.Color]::LightBlue
    $nextBtn.Enabled = $false
    $nextBtn.Add_Click({ $script:step = 5; Show-Step5 $form })
    $form.Controls.Add($nextBtn)
    
    # Progress
    $progLabel = New-Object System.Windows.Forms.Label
    $progLabel.Text = "Step 4 of 5"
    $progLabel.Top = 535
    $progLabel.Left = 20
    $progLabel.Width = 200
    $progLabel.Height = 25
    $progLabel.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
    $form.Controls.Add($progLabel)
    
    $genBtn.Add_Click({
        # A separate random value per secret - reusing one password across
        # unrelated databases/services means one leak compromises everything.
        $script:data.AuthentikPgPassword     = Generate-SecurePassword
        $script:data.AuthentikSecretKey      = Generate-SecurePassword 50
        $script:data.AuthentikBootstrapPass  = Generate-SecurePassword
        $script:data.AuthentikBootstrapToken = Generate-SecurePassword 50
        $script:data.NextcloudAdminPassword  = Generate-SecurePassword
        $script:data.NextcloudDbPassword     = Generate-SecurePassword
        $script:data.NextcloudDbRootPassword = Generate-SecurePassword
        $script:data.PaperlessAdminPassword  = Generate-SecurePassword
        $script:data.PaperlessSecretKey      = Generate-SecurePassword 50
        $script:data.PaperlessDbPassword     = Generate-SecurePassword
        $script:data.WallabagDbPassword      = Generate-SecurePassword
        $script:data.MailuSecretKey          = Generate-SecurePassword 24
        $script:data.MailAdminPassword       = Generate-SecurePassword
        $script:data.InfluxdbAdminPassword   = Generate-SecurePassword
        $script:data.InfluxdbAdminToken      = Generate-SecurePassword 32
        $script:data.GrafanaMainPassword     = Generate-SecurePassword
        $script:data.GotifyAdminPassword     = Generate-SecurePassword
        $script:data.VaultwardenAdminToken   = Generate-SecurePassword 32
        $script:data.ImmichDbPassword        = Generate-SecurePassword
        $script:data.PiholeWebPassword       = Generate-SecurePassword
        $script:data.ArrAuthPassword         = Generate-SecurePassword
        $script:data.RadicaleAuthPassword    = Generate-SecurePassword

        $statusLabel.Text = "Generating secrets... hashing two of them via Docker, one moment"
        $statusLabel.Refresh()
        try {
            $script:data.ArrAuthHash      = Get-CaddyPasswordHash -PlainSecret $script:data.ArrAuthPassword
            $script:data.RadicaleAuthHash = Get-CaddyPasswordHash -PlainSecret $script:data.RadicaleAuthPassword
        } catch {
            Show-Error "Failed to hash the Sonarr/Radarr/Radicale passwords via Docker - is Docker Desktop running?`n`n$_"
            $statusLabel.Text = "Ready to generate"
            return
        }

        $statusLabel.Text = @"
✓ Generated 22 unique secrets (one per service/database - no reuse)

All passwords generated with a cryptographic RNG.
Click Next to review, then "Create .env Files".
"@
        $genBtn.Enabled = $false
        $genBtn.Text = "✓ Done"
        $nextBtn.Enabled = $true
    })
}

function Show-Step5 {
    param($form)
    
    $form.Controls.Clear()
    
    # "and", not "&": WinForms Label text treats a single & as a mnemonic
    # marker (it gets silently swallowed rather than displayed) unless
    # doubled as && or UseMnemonic is turned off - confirmed live it
    # rendered as "Review  Create" with the & just missing.
    $titleLabel = New-Object System.Windows.Forms.Label
    $titleLabel.Text = "Step 5 of 5: Review and Create"
    $titleLabel.Top = 20
    $titleLabel.Left = 20
    $titleLabel.Width = 600
    $titleLabel.Height = 30
    $titleLabel.Font = New-Object System.Drawing.Font("Segoe UI", 13, [System.Drawing.FontStyle]::Bold)
    $form.Controls.Add($titleLabel)
    
    $descLabel = New-Object System.Windows.Forms.Label
    $descLabel.Text = "Review before creating .env files"
    $descLabel.Top = 55
    $descLabel.Left = 20
    $descLabel.Width = 600
    $descLabel.Height = 30
    $descLabel.Font = New-Object System.Drawing.Font("Segoe UI", 9)
    $descLabel.ForeColor = [System.Drawing.Color]::Gray
    $form.Controls.Add($descLabel)
    
    # Review Box
    $reviewBox = New-Object System.Windows.Forms.TextBox
    $reviewBox.Multiline = $true
    $reviewBox.ReadOnly = $true
    $reviewBox.ScrollBars = [System.Windows.Forms.ScrollBars]::Vertical
    $reviewBox.Top = 100
    $reviewBox.Left = 20
    $reviewBox.Width = 600
    $reviewBox.Height = 280
    $reviewBox.Font = New-Object System.Drawing.Font("Consolas", 9)
    $reviewBox.Text = @"
CONFIGURATION SUMMARY
═════════════════════════════════════════════

Domain: $($script:data.Domain)
Mail Domain: $($script:data.MailDomain)$(if ($script:data.MailDomain -eq $script:data.Domain) { " (same as Domain)" } else { " (separate from Domain)" })
Email: $($script:data.Email)
Timezone: $($script:data.Timezone)

Cloudflare API Token: ✓ Set
Cloudflare Tunnel Token: ✓ Set
(Reminder: the tunnel and its Public Hostname rules must already exist
in your Cloudflare dashboard - see SETUP.md if you haven't done that yet.
If Mail Domain is separate from Domain, that needs its own Public
Hostname rules and DNS-edit permission on the Cloudflare API token too.)

ProtonVPN Username: $($script:data.ProtonUsername)
ProtonVPN Country: $($script:data.ProtonCountry)

Plex Domain: $($script:data.PlexDomain)
Jellyfin Domain: $($script:data.JellyfinDomain)

Passwords: ✓ Generated (22 unique secure secrets)

═════════════════════════════════════════════
Click "Create .env Files" to proceed
"@
    $form.Controls.Add($reviewBox)
    
    # Back Button
    $backBtn = New-Object System.Windows.Forms.Button
    $backBtn.Text = "← Back"
    $backBtn.Top = 530
    $backBtn.Left = 470
    $backBtn.Width = 80
    $backBtn.Height = 35
    $backBtn.Font = New-Object System.Drawing.Font("Segoe UI", 10)
    $backBtn.Add_Click({ $script:step = 4; Show-Step4 $form })
    $form.Controls.Add($backBtn)
    
    # Create Button
    $createBtn = New-Object System.Windows.Forms.Button
    $createBtn.Text = "✓ Create .env Files"
    $createBtn.Top = 530
    $createBtn.Left = 560
    $createBtn.Width = 80
    $createBtn.Height = 35
    $createBtn.Font = New-Object System.Drawing.Font("Segoe UI", 10)
    $createBtn.BackColor = [System.Drawing.Color]::LightGreen
    $createBtn.Add_Click({
        Create-EnvFiles
        $credPath = Export-Credentials
        Show-Success "Success!`n`nAll .env files created.`n`nA password-manager-ready credentials file was also written to:`n$credPath`n`nImport it into Vaultwarden or Proton Pass (both accept Bitwarden-format CSV), then delete that file - it's plaintext and not safe to leave sitting on disk.`n`nNext:`n1. .\setup-directories.ps1`n2. .\deploy.ps1 -Action deploy`n3. .\health-check.ps1"
        $form.Close()
    })
    $form.Controls.Add($createBtn)
    
    # Progress
    $progLabel = New-Object System.Windows.Forms.Label
    $progLabel.Text = "Step 5 of 5"
    $progLabel.Top = 535
    $progLabel.Left = 20
    $progLabel.Width = 200
    $progLabel.Height = 25
    $progLabel.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
    $form.Controls.Add($progLabel)
}

function Create-EnvFiles {
    # Variable names here must exactly match what each stack's
    # docker-compose.yml actually reads via ${VAR} - see PLATFORM.md and
    # the comments in each docker-compose.yml if you're changing these.
    $d = $script:data.Domain

    $authEnv = @"
# Database Credentials
PG_USER=authentik
PG_PASS=$($script:data.AuthentikPgPassword)
PG_DB=authentik

# Authentik Security Keys
SECRET_KEY=$($script:data.AuthentikSecretKey)

# Bootstrap Credentials (for initial web UI login - username is "akadmin")
BOOTSTRAP_PASSWORD=$($script:data.AuthentikBootstrapPass)
BOOTSTRAP_TOKEN=$($script:data.AuthentikBootstrapToken)
"@
    $authEnv | Out-File "$appRoot\authentik\.env" -Encoding UTF8 -Force

    # docker compose's own .env-file parser treats a bare $ as the start of
    # a variable reference (the same issue TROUBLESHOOTING.md documents for
    # a hand-placed Portainer password hash) - every literal $ in a bcrypt
    # hash must be doubled to $$ to survive being written into a .env file,
    # or compose silently mangles it into an empty/wrong value.
    $arrAuthHashEscaped = $script:data.ArrAuthHash -replace '\$', '$$'
    $radicaleAuthHashEscaped = $script:data.RadicaleAuthHash -replace '\$', '$$'

    $caddyEnv = @"
DOMAIN=$d
ACME_EMAIL=$($script:data.Email)
# Must match QBIT_PORT in media-stack\.env exactly.
QBIT_PORT=8080
CLOUDFLARE_API_TOKEN=$($script:data.CloudflareApiToken)
CLOUDFLARE_TUNNEL_TOKEN=$($script:data.CloudflareTunnelToken)
# Same as DOMAIN unless you entered a separate Mail Domain in step 1 -
# must match DOMAIN in email-stack\.env exactly either way.
MAIL_DOMAIN=$($script:data.MailDomain)
# Shared login for Sonarr/Radarr/Prowlarr/Lidarr - see arr_auth in
# caddy/Caddyfile. Every `$` below is doubled deliberately - see comment
# above, don't "clean up" this into a single $.
ARR_AUTH_USER=admin
ARR_AUTH_HASH=$arrAuthHashEscaped
RADICALE_AUTH_USER=family
RADICALE_AUTH_HASH=$radicaleAuthHashEscaped
"@
    $caddyEnv | Out-File "$appRoot\caddy\.env" -Encoding UTF8 -Force

    $mediaEnv = @"
PROTON_OPENVPN_USERNAME=$($script:data.ProtonUsername)
PROTON_OPENVPN_PASSWORD=$($script:data.ProtonPassword)
# Only needed if you set VPN_TYPE=wireguard below.
PROTON_WIREGUARD_KEY=your-wireguard-private-key
PROTON_WIREGUARD_ADDRESSES=your-wireguard-addresses
PROTON_COUNTRIES=$($script:data.ProtonCountry)
VPN_TYPE=openvpn

# qBittorrent WebUI port - static. Must match caddy\.env's QBIT_PORT.
QBIT_PORT=8080
# BitTorrent peer port - update after checking gluetun logs for the port
# ProtonVPN actually forwards you. Must differ from QBIT_PORT.
BT_PORT=6969

QBIT_DOWNLOADS_PATH=D:\Media\Downloads
MEDIA_MOVIES=D:\Media\Movies
MEDIA_TV=D:\Media\TV
MEDIA_MUSIC=D:\Media\Music
MEDIA_BOOKS=D:\Media\Books
MEDIA_PHOTOS=D:\Media\Photos

PLEX_CLAIM_TOKEN=$($script:data.PlexToken)
PLEX_DOMAIN=$($script:data.PlexDomain)
JELLYFIN_DOMAIN=$($script:data.JellyfinDomain)

TZ=$($script:data.Timezone)
"@
    $mediaEnv | Out-File "$appRoot\media-stack\.env" -Encoding UTF8 -Force

    $privacyEnv = @"
DOMAIN=$d
MEDIA_MUSIC=D:\Media\Music
SYNC_FOLDER=D:\Sync

NEXTCLOUD_ADMIN_USER=admin
NEXTCLOUD_ADMIN_PASSWORD=$($script:data.NextcloudAdminPassword)
NEXTCLOUD_DB_PASS=$($script:data.NextcloudDbPassword)
NEXTCLOUD_DB_ROOT_PASS=$($script:data.NextcloudDbRootPassword)
NEXTCLOUD_DATA=D:\Nextcloud

PAPERLESS_ADMIN_USER=admin
PAPERLESS_ADMIN_PASSWORD=$($script:data.PaperlessAdminPassword)
PAPERLESS_SECRET_KEY=$($script:data.PaperlessSecretKey)
PAPERLESS_DB_PASS=$($script:data.PaperlessDbPassword)
PAPERLESS_CONSUME=D:\Paperless\consume

WALLABAG_DB_PASS=$($script:data.WallabagDbPassword)
WALLABAG_EMAIL=$($script:data.Email)
MAILER_HOST=smtp.gmail.com
MAILER_PORT=587
"@
    $privacyEnv | Out-File "$appRoot\privacy-stack\.env" -Encoding UTF8 -Force

    $emailEnv = @"
# Same as caddy\.env's MAIL_DOMAIN - must match exactly.
DOMAIN=$($script:data.MailDomain)
MAILU_SECRET_KEY=$($script:data.MailuSecretKey)
MAIL_ADMIN_USER=admin
MAIL_ADMIN_PASSWORD=$($script:data.MailAdminPassword)
TZ=$($script:data.Timezone)
"@
    $emailEnv | Out-File "$appRoot\email-stack\.env" -Encoding UTF8 -Force

    $securityEnv = @"
DOMAIN=$d
WIREGUARD_DOMAIN=vpn.$d
TZ=$($script:data.Timezone)
"@
    $securityEnv | Out-File "$appRoot\security-stack\.env" -Encoding UTF8 -Force

    $monitoringEnv = @"
DOMAIN=$d
INFLUXDB_ADMIN_USER=admin
INFLUXDB_ADMIN_PASSWORD=$($script:data.InfluxdbAdminPassword)
# Must match INFLUXDB_ADMIN_TOKEN in utilities\.env exactly - the one
# Grafana instance (in utilities) uses this to query InfluxDB.
INFLUXDB_ADMIN_TOKEN=$($script:data.InfluxdbAdminToken)
TZ=$($script:data.Timezone)
"@
    $monitoringEnv | Out-File "$appRoot\monitoring-stack\.env" -Encoding UTF8 -Force

    $notificationEnv = @"
DOMAIN=$d
GOTIFY_ADMIN_USER=admin
GOTIFY_ADMIN_PASSWORD=$($script:data.GotifyAdminPassword)
TZ=$($script:data.Timezone)
"@
    $notificationEnv | Out-File "$appRoot\notification-stack\.env" -Encoding UTF8 -Force

    $utilitiesEnv = @"
DOMAIN=$d
VAULTWARDEN_ADMIN_TOKEN=$($script:data.VaultwardenAdminToken)
VAULTWARDEN_SIGNUPS_ALLOWED=false
VAULTWARDEN_INVITATIONS_ALLOWED=true
GRAFANA_ADMIN_USER=admin
GRAFANA_ADMIN_PASSWORD=$($script:data.GrafanaMainPassword)
# Must match INFLUXDB_ADMIN_TOKEN in monitoring-stack\.env exactly.
INFLUXDB_ADMIN_TOKEN=$($script:data.InfluxdbAdminToken)
"@
    $utilitiesEnv | Out-File "$appRoot\utilities\.env" -Encoding UTF8 -Force

    $immichEnv = @"
# You can find documentation for all the supported env variables at https://immich.app/docs/install/environment-variables
UPLOAD_LOCATION=./library
DB_DATA_LOCATION=./postgres
IMMICH_VERSION=v3.2.2
DB_PASSWORD=$($script:data.ImmichDbPassword)
DB_USERNAME=postgres
DB_DATABASE_NAME=immich
"@
    $immichEnv | Out-File "$appRoot\immich-app\.env" -Encoding UTF8 -Force

    $dashboardEnv = @"
DOMAIN=$d
"@
    $dashboardEnv | Out-File "$appRoot\dashboard\.env" -Encoding UTF8 -Force

    $dnsEnv = @"
PIHOLE_WEBPASSWORD=$($script:data.PiholeWebPassword)
TZ=$($script:data.Timezone)
"@
    $dnsEnv | Out-File "$appRoot\dns-stack\.env" -Encoding UTF8 -Force
}

function Export-Credentials {
    # Writes every credential this wizard just generated (or collected) to
    # one CSV in Bitwarden's import format - Vaultwarden speaks it
    # natively, and Proton Pass explicitly supports "Bitwarden (csv)" as
    # an import source, so this one file drops into either without any
    # reformatting. This is the file SECURITY.md means by "back up your
    # secrets" - it's plaintext, gitignored, and meant to be imported and
    # then deleted, not kept sitting on disk.
    $d = $script:data.Domain
    $md = $script:data.MailDomain
    $rows = [System.Collections.Generic.List[PSCustomObject]]::new()

    function New-CredRow {
        param([string]$Name, [string]$Uri = "", [string]$Login = "", [string]$Secret = "", [string]$Notes = "")
        [PSCustomObject]@{
            folder         = "Homelab"
            favorite       = ""
            type           = "login"
            name           = $Name
            notes          = $Notes
            fields         = ""
            reprompt       = ""
            login_uri      = $Uri
            login_username = $Login
            login_password = $Secret
            login_totp     = ""
        }
    }

    $rows.Add((New-CredRow "Cloudflare API Token" "https://dash.cloudflare.com/profile/api-tokens" "" $script:data.CloudflareApiToken "Zone:DNS:Edit token - used by Caddy for certificate issuance (caddy/.env)"))
    $rows.Add((New-CredRow "Cloudflare Tunnel Token" "https://one.dash.cloudflare.com" "" $script:data.CloudflareTunnelToken "Used by the cloudflared container (caddy/.env)"))
    $rows.Add((New-CredRow "Authentik (SSO)" "https://auth.$d" "akadmin" $script:data.AuthentikBootstrapPass "Bootstrap admin account - authentik/.env BOOTSTRAP_PASSWORD"))
    $rows.Add((New-CredRow "Authentik Bootstrap Token" "https://auth.$d" "" $script:data.AuthentikBootstrapToken "API token, not a login password"))
    $rows.Add((New-CredRow "Authentik Database" "" "authentik" $script:data.AuthentikPgPassword "Internal Postgres password - not a login page"))
    $rows.Add((New-CredRow "Nextcloud" "https://nextcloud.$d" "admin" $script:data.NextcloudAdminPassword "Auto-provisioned from .env on first boot"))
    $rows.Add((New-CredRow "Nextcloud Database" "" "nextcloud" $script:data.NextcloudDbPassword "Internal MariaDB password - not a login page"))
    $rows.Add((New-CredRow "Nextcloud Database Root" "" "root" $script:data.NextcloudDbRootPassword "Internal MariaDB root password - not a login page"))
    $rows.Add((New-CredRow "Paperless-ngx" "https://papers.$d" "admin" $script:data.PaperlessAdminPassword "Auto-provisioned from .env on first boot"))
    $rows.Add((New-CredRow "Paperless-ngx Database" "" "paperless" $script:data.PaperlessDbPassword "Internal Postgres password - not a login page"))
    $rows.Add((New-CredRow "Wallabag Database" "" "wallabag" $script:data.WallabagDbPassword "Internal Postgres password - not a login page"))
    $rows.Add((New-CredRow "Wallabag App Login" "https://read.$d" "wallabag" "" "Ships with default password 'wallabag' - change on first login, then fill in here"))
    $rows.Add((New-CredRow "Mailu Admin / Webmail" "https://mailadmin.$md" "admin" $script:data.MailAdminPassword "Same login also works at webmail.$md"))
    $rows.Add((New-CredRow "Mailu Secret Key" "" "" $script:data.MailuSecretKey "Internal session-signing key, not a login password"))
    $rows.Add((New-CredRow "InfluxDB Admin" "" "admin" $script:data.InfluxdbAdminPassword "No direct web route published - reached via Grafana"))
    $rows.Add((New-CredRow "InfluxDB API Token" "" "" $script:data.InfluxdbAdminToken "API token, not a login password"))
    $rows.Add((New-CredRow "Grafana" "https://grafana.$d" "admin" $script:data.GrafanaMainPassword ""))
    $rows.Add((New-CredRow "Gotify" "https://gotify.$d" "admin" $script:data.GotifyAdminPassword ""))
    $rows.Add((New-CredRow "Vaultwarden Admin Panel" "https://vault.$d/admin" "" $script:data.VaultwardenAdminToken "Token-based admin panel login, no username"))
    $rows.Add((New-CredRow "Immich Database" "" "postgres" $script:data.ImmichDbPassword "Internal Postgres password - not a login page"))
    $rows.Add((New-CredRow "Pi-hole" "https://pihole.$d" "" $script:data.PiholeWebPassword "Password-only login, no username"))
    $rows.Add((New-CredRow "Sonarr / Radarr / Prowlarr / Lidarr" "https://sonarr.$d" "admin" $script:data.ArrAuthPassword "Shared Caddy basic-auth login - same credential works at radarr./prowlarr./lidarr.$d too"))
    $rows.Add((New-CredRow "Radicale (Calendar/Contacts)" "https://cal.$d" "family" $script:data.RadicaleAuthPassword "Caddy basic-auth in front of Radicale, which has no auth of its own"))
    $rows.Add((New-CredRow "ProtonVPN" "https://account.protonvpn.com" $script:data.ProtonUsername $script:data.ProtonPassword "Used by media-stack's gluetun VPN routing"))
    $rows.Add((New-CredRow "Portainer" "https://portainer.$d" "" "" "Set your own password on first visit, then fill in here"))
    $rows.Add((New-CredRow "Trilium" "https://notes.$d" "" "" "Set your own password on first visit, then fill in here"))
    $rows.Add((New-CredRow "Focalboard" "https://boards.$d" "" "" "Set your own password on first visit, then fill in here"))
    $rows.Add((New-CredRow "Jellyfin" "https://jellyfin.$d" "" "" "Set your own admin account on first visit, then fill in here"))

    $exportPath = "$appRoot\credentials-export.csv"
    $rows | Select-Object folder, favorite, type, name, notes, fields, reprompt, login_uri, login_username, login_password, login_totp |
        Export-Csv -Path $exportPath -NoTypeInformation -Encoding UTF8
    return $exportPath
}

$form = Create-Form
Show-Step1 $form
$form.ShowDialog() | Out-Null
