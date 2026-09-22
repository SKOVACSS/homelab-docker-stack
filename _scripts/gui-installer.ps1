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
    $f.Height = 680
    $f.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
    $f.BackColor = [System.Drawing.Color]::White
    $f.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
    $f.MaximizeBox = $false
    $f.MinimizeBox = $false
    return $f
}

function Show-Step1 {

    $script:form.Controls.Clear()

    # Title
    $titleLabel = New-Object System.Windows.Forms.Label
    $titleLabel.Text = "Step 1 of 5: Basic Configuration"
    $titleLabel.Top = 20
    $titleLabel.Left = 20
    $titleLabel.Width = 600
    $titleLabel.Height = 30
    $titleLabel.Font = New-Object System.Drawing.Font("Segoe UI", 13, [System.Drawing.FontStyle]::Bold)
    $script:form.Controls.Add($titleLabel)

    # Description
    $descLabel = New-Object System.Windows.Forms.Label
    $descLabel.Text = "Enter your domain, email, and Cloudflare credentials"
    $descLabel.Top = 55
    $descLabel.Left = 20
    $descLabel.Width = 600
    $descLabel.Height = 30
    $descLabel.Font = New-Object System.Drawing.Font("Segoe UI", 9)
    $descLabel.ForeColor = [System.Drawing.Color]::Gray
    $script:form.Controls.Add($descLabel)

    # Domain Label
    $domainLabelCtrl = New-Object System.Windows.Forms.Label
    $domainLabelCtrl.Text = "Domain Name (e.g., yourdomain.com)"
    $domainLabelCtrl.Top = 100
    $domainLabelCtrl.Left = 20
    $domainLabelCtrl.Width = 600
    $domainLabelCtrl.Height = 20
    $domainLabelCtrl.Font = New-Object System.Drawing.Font("Segoe UI", 10)
    $script:form.Controls.Add($domainLabelCtrl)

    # Domain TextBox - script-scoped: read later from $nextBtn's Add_Click,
    # which fires from the WinForms message loop long after this function
    # has returned, so a local variable here would already be out of scope
    # by then (see CHANGELOG - this whole wizard once silently read every
    # field as empty because of exactly that).
    $script:domainBox = New-Object System.Windows.Forms.TextBox
    $script:domainBox.Top = 120
    $script:domainBox.Left = 20
    $script:domainBox.Width = 600
    $script:domainBox.Height = 30
    $script:domainBox.Font = New-Object System.Drawing.Font("Consolas", 10)
    $script:domainBox.Text = "yourdomain.com"
    $script:form.Controls.Add($script:domainBox)

    # Email Label
    $emailLabelCtrl = New-Object System.Windows.Forms.Label
    $emailLabelCtrl.Text = "Email for SSL (e.g., admin@yourdomain.com)"
    $emailLabelCtrl.Top = 160
    $emailLabelCtrl.Left = 20
    $emailLabelCtrl.Width = 600
    $emailLabelCtrl.Height = 20
    $emailLabelCtrl.Font = New-Object System.Drawing.Font("Segoe UI", 10)
    $script:form.Controls.Add($emailLabelCtrl)

    # Email TextBox
    $script:emailBox = New-Object System.Windows.Forms.TextBox
    $script:emailBox.Top = 180
    $script:emailBox.Left = 20
    $script:emailBox.Width = 600
    $script:emailBox.Height = 30
    $script:emailBox.Font = New-Object System.Drawing.Font("Consolas", 10)
    $script:emailBox.Text = "admin@yourdomain.com"
    $script:form.Controls.Add($script:emailBox)

    # Timezone Label
    $tzLabelCtrl = New-Object System.Windows.Forms.Label
    $tzLabelCtrl.Text = "Timezone"
    $tzLabelCtrl.Top = 220
    $tzLabelCtrl.Left = 20
    $tzLabelCtrl.Width = 600
    $tzLabelCtrl.Height = 20
    $tzLabelCtrl.Font = New-Object System.Drawing.Font("Segoe UI", 10)
    $script:form.Controls.Add($tzLabelCtrl)

    # Timezone ComboBox
    $script:tzBox = New-Object System.Windows.Forms.ComboBox
    $script:tzBox.Top = 240
    $script:tzBox.Left = 20
    $script:tzBox.Width = 600
    $script:tzBox.Height = 30
    $script:tzBox.Font = New-Object System.Drawing.Font("Segoe UI", 10)
    $script:tzBox.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
    @("UTC", "US/Eastern", "US/Central", "US/Mountain", "US/Pacific", "Europe/London", "Europe/Paris", "Australia/Sydney") | ForEach-Object { $script:tzBox.Items.Add($_) | Out-Null }
    $script:tzBox.SelectedIndex = 0
    $script:form.Controls.Add($script:tzBox)

    # Cloudflare info label
    $cfInfoLabel = New-Object System.Windows.Forms.Label
    $cfInfoLabel.Text = "Cloudflare Tunnel (for remote access behind CGNAT) - see SETUP.md for how to create these"
    $cfInfoLabel.Top = 280
    $cfInfoLabel.Left = 20
    $cfInfoLabel.Width = 600
    $cfInfoLabel.Height = 20
    $cfInfoLabel.Font = New-Object System.Drawing.Font("Segoe UI", 8, [System.Drawing.FontStyle]::Italic)
    $cfInfoLabel.ForeColor = [System.Drawing.Color]::Blue
    $script:form.Controls.Add($cfInfoLabel)

    # Cloudflare API Token Label
    $cfApiLabelCtrl = New-Object System.Windows.Forms.Label
    $cfApiLabelCtrl.Text = "Cloudflare API Token (Zone:DNS:Edit, scoped to your domain)"
    $cfApiLabelCtrl.Top = 305
    $cfApiLabelCtrl.Left = 20
    $cfApiLabelCtrl.Width = 600
    $cfApiLabelCtrl.Height = 20
    $cfApiLabelCtrl.Font = New-Object System.Drawing.Font("Segoe UI", 10)
    $script:form.Controls.Add($cfApiLabelCtrl)

    # Cloudflare API Token TextBox
    $script:cfApiBox = New-Object System.Windows.Forms.TextBox
    $script:cfApiBox.Top = 325
    $script:cfApiBox.Left = 20
    $script:cfApiBox.Width = 600
    $script:cfApiBox.Height = 30
    $script:cfApiBox.Font = New-Object System.Drawing.Font("Consolas", 10)
    $script:cfApiBox.UseSystemPasswordChar = $true
    $script:form.Controls.Add($script:cfApiBox)

    # Cloudflare Tunnel Token Label
    $cfTunnelLabelCtrl = New-Object System.Windows.Forms.Label
    $cfTunnelLabelCtrl.Text = "Cloudflare Tunnel Token (Zero Trust -> Networks -> Tunnels)"
    $cfTunnelLabelCtrl.Top = 365
    $cfTunnelLabelCtrl.Left = 20
    $cfTunnelLabelCtrl.Width = 600
    $cfTunnelLabelCtrl.Height = 20
    $cfTunnelLabelCtrl.Font = New-Object System.Drawing.Font("Segoe UI", 10)
    $script:form.Controls.Add($cfTunnelLabelCtrl)

    # Cloudflare Tunnel Token TextBox
    $script:cfTunnelBox = New-Object System.Windows.Forms.TextBox
    $script:cfTunnelBox.Top = 385
    $script:cfTunnelBox.Left = 20
    $script:cfTunnelBox.Width = 600
    $script:cfTunnelBox.Height = 30
    $script:cfTunnelBox.Font = New-Object System.Drawing.Font("Consolas", 10)
    $script:cfTunnelBox.UseSystemPasswordChar = $true
    $script:form.Controls.Add($script:cfTunnelBox)

    # Set Up Email Server checkbox - unchecked by default. Mailu is by far
    # the most complex, fragile stack in this repo (see CHANGELOG's 1.0.9,
    # 1.2.2, and 1.5.0 entries for the real bugs found in it) - someone
    # using this installer to help set up a homelab for family/friends, or
    # setting up new hardware later, may well not want an email server at
    # all. Leaving it unchecked writes no email-stack/.env at all: the
    # stack stays fully present in the repo, just not configured or
    # deployed - see _scripts/enable-email.ps1 for turning it on later
    # without re-running this whole wizard.
    $script:emailSetupCheckbox = New-Object System.Windows.Forms.CheckBox
    $script:emailSetupCheckbox.Text = "Set up email server (Mailu) now"
    $script:emailSetupCheckbox.Top = 425
    $script:emailSetupCheckbox.Left = 20
    $script:emailSetupCheckbox.Width = 400
    $script:emailSetupCheckbox.Height = 24
    $script:emailSetupCheckbox.Font = New-Object System.Drawing.Font("Segoe UI", 10)
    $script:emailSetupCheckbox.Checked = $false
    $script:form.Controls.Add($script:emailSetupCheckbox)

    # Mail Domain Label
    $script:mailDomainLabelCtrl = New-Object System.Windows.Forms.Label
    $script:mailDomainLabelCtrl.Text = "Mail Domain (optional - only if Mailu needs a DIFFERENT domain than above, e.g. main domain already has real email elsewhere)"
    $script:mailDomainLabelCtrl.Top = 453
    $script:mailDomainLabelCtrl.Left = 20
    $script:mailDomainLabelCtrl.Width = 600
    $script:mailDomainLabelCtrl.Height = 20
    $script:mailDomainLabelCtrl.Font = New-Object System.Drawing.Font("Segoe UI", 8)
    $script:mailDomainLabelCtrl.Enabled = $false
    $script:form.Controls.Add($script:mailDomainLabelCtrl)

    # Mail Domain TextBox
    $script:mailDomainBox = New-Object System.Windows.Forms.TextBox
    $script:mailDomainBox.Top = 473
    $script:mailDomainBox.Left = 20
    $script:mailDomainBox.Width = 600
    $script:mailDomainBox.Height = 30
    $script:mailDomainBox.Font = New-Object System.Drawing.Font("Consolas", 10)
    $script:mailDomainBox.Enabled = $false
    $script:form.Controls.Add($script:mailDomainBox)

    # Mail Domain only means anything if email is actually being set up
    # now - greyed out otherwise rather than removed, so it's obvious the
    # option exists and why it's currently unavailable. Every control here
    # is $script:-scoped (see note on $domainBox above) since this handler
    # also fires from outside Show-Step1's own call frame.
    $script:emailSetupCheckbox.Add_CheckedChanged({
        $script:mailDomainLabelCtrl.Enabled = $script:emailSetupCheckbox.Checked
        $script:mailDomainBox.Enabled = $script:emailSetupCheckbox.Checked
    })

    # Back Button
    $backBtn = New-Object System.Windows.Forms.Button
    $backBtn.Text = "← Back"
    $backBtn.Top = 590
    $backBtn.Left = 470
    $backBtn.Width = 80
    $backBtn.Height = 35
    $backBtn.Enabled = $false
    $backBtn.Font = New-Object System.Drawing.Font("Segoe UI", 10)
    $script:form.Controls.Add($backBtn)

    # Next Button
    $nextBtn = New-Object System.Windows.Forms.Button
    $nextBtn.Text = "Next →"
    $nextBtn.Top = 590
    $nextBtn.Left = 560
    $nextBtn.Width = 80
    $nextBtn.Height = 35
    $nextBtn.Font = New-Object System.Drawing.Font("Segoe UI", 10)
    $nextBtn.BackColor = [System.Drawing.Color]::LightBlue
    $script:form.Controls.Add($nextBtn)

    # Progress
    $progLabel = New-Object System.Windows.Forms.Label
    $progLabel.Text = "Step 1 of 5"
    $progLabel.Top = 595
    $progLabel.Left = 20
    $progLabel.Width = 200
    $progLabel.Height = 25
    $progLabel.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
    $script:form.Controls.Add($progLabel)

    $nextBtn.Add_Click({
        $domain = $script:domainBox.Text.Trim()
        $email = $script:emailBox.Text.Trim()
        $cfApiToken = $script:cfApiBox.Text.Trim()
        $cfTunnelToken = $script:cfTunnelBox.Text.Trim()
        $setupEmail = $script:emailSetupCheckbox.Checked
        $mailDomain = $script:mailDomainBox.Text.Trim()

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
        # Mail Domain's format only matters if email is actually being set
        # up now (the box is disabled otherwise, but its old text could
        # still be sitting there if the checkbox was unchecked after typing).
        if ($setupEmail -and -not [string]::IsNullOrEmpty($mailDomain) -and -not (Validate-Domain $mailDomain)) { Show-Error "Invalid Mail Domain format"; return }

        $script:data.Domain = $domain
        $script:data.Email = $email
        $script:data.Timezone = $script:tzBox.SelectedItem
        $script:data.CloudflareApiToken = $cfApiToken
        $script:data.CloudflareTunnelToken = $cfTunnelToken
        $script:data.SetupEmail = $setupEmail
        # Falls back to the main domain when left blank - see caddy/.env's
        # MAIL_DOMAIN and email-stack/.env's DOMAIN. Meaningless (and left
        # unset) when email isn't being set up at all.
        if ($setupEmail) {
            $script:data.MailDomain = if ([string]::IsNullOrEmpty($mailDomain)) { $domain } else { $mailDomain }
        }

        $script:step = 2
        Show-Step2
    })
}

function Show-Step2 {

    $script:form.Controls.Clear()

    $titleLabel = New-Object System.Windows.Forms.Label
    $titleLabel.Text = "Step 2 of 5: ProtonVPN Configuration"
    $titleLabel.Top = 20
    $titleLabel.Left = 20
    $titleLabel.Width = 600
    $titleLabel.Height = 30
    $titleLabel.Font = New-Object System.Drawing.Font("Segoe UI", 13, [System.Drawing.FontStyle]::Bold)
    $script:form.Controls.Add($titleLabel)

    $descLabel = New-Object System.Windows.Forms.Label
    $descLabel.Text = "Enter your ProtonVPN OpenVPN credentials"
    $descLabel.Top = 55
    $descLabel.Left = 20
    $descLabel.Width = 600
    $descLabel.Height = 30
    $descLabel.Font = New-Object System.Drawing.Font("Segoe UI", 9)
    $descLabel.ForeColor = [System.Drawing.Color]::Gray
    $script:form.Controls.Add($descLabel)

    $infoLabel = New-Object System.Windows.Forms.Label
    $infoLabel.Text = "Get from: https://account.protonvpn.com/account#downloads (OpenVPN Credentials)"
    $infoLabel.Top = 100
    $infoLabel.Left = 20
    $infoLabel.Width = 600
    $infoLabel.Height = 40
    $infoLabel.Font = New-Object System.Drawing.Font("Segoe UI", 8, [System.Drawing.FontStyle]::Italic)
    $infoLabel.ForeColor = [System.Drawing.Color]::Blue
    $script:form.Controls.Add($infoLabel)

    # ProtonVPN Username Label
    $userLabelCtrl = New-Object System.Windows.Forms.Label
    $userLabelCtrl.Text = "ProtonVPN Username (username+sXXXXXX@protonvpn.com)"
    $userLabelCtrl.Top = 150
    $userLabelCtrl.Left = 20
    $userLabelCtrl.Width = 600
    $userLabelCtrl.Height = 20
    $userLabelCtrl.Font = New-Object System.Drawing.Font("Segoe UI", 10)
    $script:form.Controls.Add($userLabelCtrl)

    # ProtonVPN Username TextBox
    $script:userBox = New-Object System.Windows.Forms.TextBox
    $script:userBox.Top = 170
    $script:userBox.Left = 20
    $script:userBox.Width = 600
    $script:userBox.Height = 30
    $script:userBox.Font = New-Object System.Drawing.Font("Consolas", 10)
    $script:form.Controls.Add($script:userBox)

    # ProtonVPN Password Label
    $passLabelCtrl = New-Object System.Windows.Forms.Label
    $passLabelCtrl.Text = "ProtonVPN Password"
    $passLabelCtrl.Top = 210
    $passLabelCtrl.Left = 20
    $passLabelCtrl.Width = 600
    $passLabelCtrl.Height = 20
    $passLabelCtrl.Font = New-Object System.Drawing.Font("Segoe UI", 10)
    $script:form.Controls.Add($passLabelCtrl)

    # ProtonVPN Password TextBox
    $script:passBox = New-Object System.Windows.Forms.TextBox
    $script:passBox.Top = 230
    $script:passBox.Left = 20
    $script:passBox.Width = 600
    $script:passBox.Height = 30
    $script:passBox.Font = New-Object System.Drawing.Font("Consolas", 10)
    $script:passBox.UseSystemPasswordChar = $true
    $script:form.Controls.Add($script:passBox)

    # Country Label
    $countryLabelCtrl = New-Object System.Windows.Forms.Label
    $countryLabelCtrl.Text = "VPN Country"
    $countryLabelCtrl.Top = 270
    $countryLabelCtrl.Left = 20
    $countryLabelCtrl.Width = 600
    $countryLabelCtrl.Height = 20
    $countryLabelCtrl.Font = New-Object System.Drawing.Font("Segoe UI", 10)
    $script:form.Controls.Add($countryLabelCtrl)

    # Country ComboBox
    $script:countryBox = New-Object System.Windows.Forms.ComboBox
    $script:countryBox.Top = 290
    $script:countryBox.Left = 20
    $script:countryBox.Width = 600
    $script:countryBox.Height = 30
    $script:countryBox.Font = New-Object System.Drawing.Font("Segoe UI", 10)
    $script:countryBox.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
    # gluetun's ProtonVPN provider validates SERVER_COUNTRIES against full
    # country names, not ISO codes - "US" fails with "the country specified
    # is not valid", confirmed live against a real deploy.
    @("United States", "United Kingdom", "Canada", "Australia", "Germany", "Netherlands", "France", "Switzerland") | ForEach-Object { $script:countryBox.Items.Add($_) | Out-Null }
    $script:countryBox.SelectedIndex = 0
    $script:form.Controls.Add($script:countryBox)

    # Back Button
    $backBtn = New-Object System.Windows.Forms.Button
    $backBtn.Text = "← Back"
    $backBtn.Top = 590
    $backBtn.Left = 470
    $backBtn.Width = 80
    $backBtn.Height = 35
    $backBtn.Font = New-Object System.Drawing.Font("Segoe UI", 10)
    $backBtn.Add_Click({ $script:step = 1; Show-Step1 })
    $script:form.Controls.Add($backBtn)

    # Next Button
    $nextBtn = New-Object System.Windows.Forms.Button
    $nextBtn.Text = "Next →"
    $nextBtn.Top = 590
    $nextBtn.Left = 560
    $nextBtn.Width = 80
    $nextBtn.Height = 35
    $nextBtn.Font = New-Object System.Drawing.Font("Segoe UI", 10)
    $nextBtn.BackColor = [System.Drawing.Color]::LightBlue
    $nextBtn.Add_Click({
        $user = $script:userBox.Text.Trim()
        $pass = $script:passBox.Text.Trim()

        if ([string]::IsNullOrEmpty($user)) { Show-Error "ProtonVPN Username is required"; return }
        if ([string]::IsNullOrEmpty($pass)) { Show-Error "ProtonVPN Password is required"; return }

        $script:data.ProtonUsername = $user
        $script:data.ProtonPassword = $pass
        $script:data.ProtonCountry = $script:countryBox.SelectedItem

        $script:step = 3
        Show-Step3
    })
    $script:form.Controls.Add($nextBtn)

    # Progress
    $progLabel = New-Object System.Windows.Forms.Label
    $progLabel.Text = "Step 2 of 5"
    $progLabel.Top = 595
    $progLabel.Left = 20
    $progLabel.Width = 200
    $progLabel.Height = 25
    $progLabel.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
    $script:form.Controls.Add($progLabel)
}

function Show-Step3 {

    $script:form.Controls.Clear()

    $titleLabel = New-Object System.Windows.Forms.Label
    $titleLabel.Text = "Step 3 of 5: Plex Token"
    $titleLabel.Top = 20
    $titleLabel.Left = 20
    $titleLabel.Width = 600
    $titleLabel.Height = 30
    $titleLabel.Font = New-Object System.Drawing.Font("Segoe UI", 13, [System.Drawing.FontStyle]::Bold)
    $script:form.Controls.Add($titleLabel)

    $descLabel = New-Object System.Windows.Forms.Label
    $descLabel.Text = "Optional: pre-claim your Plex server so it's already signed into your account on first boot"
    $descLabel.Top = 55
    $descLabel.Left = 20
    $descLabel.Width = 600
    $descLabel.Height = 30
    $descLabel.Font = New-Object System.Drawing.Font("Segoe UI", 9)
    $descLabel.ForeColor = [System.Drawing.Color]::Gray
    $script:form.Controls.Add($descLabel)

    $warnLabel = New-Object System.Windows.Forms.Label
    # Leave this blank in practice: the token expires in 4 minutes, but
    # setup-directories.ps1 and deploy.ps1 (which builds a custom Caddy
    # image first) run as SEPARATE steps after this wizard finishes, so by
    # the time the Plex container actually starts, several minutes have
    # almost always passed and the token is already dead. An
    # expired/invalid PLEX_CLAIM just makes plexinc/pms-docker start
    # unclaimed - no error, no crash - so skipping this is the normal path,
    # not a degraded one. Claim it afterward at http://<this-pc>:32400/web
    # by signing into your Plex account there instead - no time pressure.
    $warnLabel.Text = "Leave blank and claim manually after deploying (recommended - see below). If you do want to fill this in, get the token from https://plex.tv/claim and finish this whole wizard, setup-directories.ps1, AND deploy.ps1 within about 4 minutes - otherwise it'll already be expired by the time Plex starts."
    $warnLabel.Top = 100
    $warnLabel.Left = 20
    $warnLabel.Width = 600
    $warnLabel.Height = 50
    $warnLabel.Font = New-Object System.Drawing.Font("Segoe UI", 8, [System.Drawing.FontStyle]::Italic)
    $warnLabel.ForeColor = [System.Drawing.Color]::Blue
    $script:form.Controls.Add($warnLabel)

    # Token Label
    $tokenLabelCtrl = New-Object System.Windows.Forms.Label
    $tokenLabelCtrl.Text = "Plex Claim Token (optional)"
    $tokenLabelCtrl.Top = 160
    $tokenLabelCtrl.Left = 20
    $tokenLabelCtrl.Width = 600
    $tokenLabelCtrl.Height = 20
    $tokenLabelCtrl.Font = New-Object System.Drawing.Font("Segoe UI", 10)
    $script:form.Controls.Add($tokenLabelCtrl)

    # Token TextBox
    $script:tokenBox = New-Object System.Windows.Forms.TextBox
    $script:tokenBox.Top = 180
    $script:tokenBox.Left = 20
    $script:tokenBox.Width = 600
    $script:tokenBox.Height = 30
    $script:tokenBox.Font = New-Object System.Drawing.Font("Consolas", 10)
    $script:form.Controls.Add($script:tokenBox)

    # Back Button
    $backBtn = New-Object System.Windows.Forms.Button
    $backBtn.Text = "← Back"
    $backBtn.Top = 590
    $backBtn.Left = 470
    $backBtn.Width = 80
    $backBtn.Height = 35
    $backBtn.Font = New-Object System.Drawing.Font("Segoe UI", 10)
    $backBtn.Add_Click({ $script:step = 2; Show-Step2 })
    $script:form.Controls.Add($backBtn)

    # Next Button
    $nextBtn = New-Object System.Windows.Forms.Button
    $nextBtn.Text = "Next →"
    $nextBtn.Top = 590
    $nextBtn.Left = 560
    $nextBtn.Width = 80
    $nextBtn.Height = 35
    $nextBtn.Font = New-Object System.Drawing.Font("Segoe UI", 10)
    $nextBtn.BackColor = [System.Drawing.Color]::LightBlue
    $nextBtn.Add_Click({
        $token = $script:tokenBox.Text.Trim()
        # Optional - see $warnLabel above for why leaving it blank is the
        # normal path, not a fallback. Only validated when something was
        # actually typed in.
        if (-not [string]::IsNullOrEmpty($token) -and -not $token.StartsWith("claim-")) { Show-Error "Token should start with 'claim-'"; return }

        $script:data.PlexToken = $token
        $script:data.PlexDomain = "plex.$($script:data.Domain)"
        $script:data.JellyfinDomain = "jellyfin.$($script:data.Domain)"

        $script:step = 4
        Show-Step4
    })
    $script:form.Controls.Add($nextBtn)

    # Progress
    $progLabel = New-Object System.Windows.Forms.Label
    $progLabel.Text = "Step 3 of 5"
    $progLabel.Top = 595
    $progLabel.Left = 20
    $progLabel.Width = 200
    $progLabel.Height = 25
    $progLabel.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
    $script:form.Controls.Add($progLabel)
}

function Show-Step4 {

    $script:form.Controls.Clear()

    $titleLabel = New-Object System.Windows.Forms.Label
    $titleLabel.Text = "Step 4 of 5: Generate Passwords"
    $titleLabel.Top = 20
    $titleLabel.Left = 20
    $titleLabel.Width = 600
    $titleLabel.Height = 30
    $titleLabel.Font = New-Object System.Drawing.Font("Segoe UI", 13, [System.Drawing.FontStyle]::Bold)
    $script:form.Controls.Add($titleLabel)

    $descLabel = New-Object System.Windows.Forms.Label
    $descLabel.Text = "Click button to generate secure passwords"
    $descLabel.Top = 55
    $descLabel.Left = 20
    $descLabel.Width = 600
    $descLabel.Height = 30
    $descLabel.Font = New-Object System.Drawing.Font("Segoe UI", 9)
    $descLabel.ForeColor = [System.Drawing.Color]::Gray
    $script:form.Controls.Add($descLabel)

    # Generate Button - script-scoped: Add_Click below both sets its own
    # Enabled/Text and reaches over to $script:nextBtn, so both buttons
    # need to survive past this function returning.
    $script:genBtn = New-Object System.Windows.Forms.Button
    $script:genBtn.Text = "Generate Passwords"
    $script:genBtn.Top = 120
    $script:genBtn.Left = 125
    $script:genBtn.Width = 400
    $script:genBtn.Height = 50
    $script:genBtn.Font = New-Object System.Drawing.Font("Segoe UI", 11, [System.Drawing.FontStyle]::Bold)
    $script:genBtn.BackColor = [System.Drawing.Color]::LightGreen
    $script:form.Controls.Add($script:genBtn)

    # Status Label
    $script:statusLabel = New-Object System.Windows.Forms.Label
    $script:statusLabel.Text = "Ready to generate"
    $script:statusLabel.Top = 190
    $script:statusLabel.Left = 20
    $script:statusLabel.Width = 600
    $script:statusLabel.Height = 150
    $script:statusLabel.Font = New-Object System.Drawing.Font("Segoe UI", 9)
    $script:form.Controls.Add($script:statusLabel)

    # Back Button
    $backBtn = New-Object System.Windows.Forms.Button
    $backBtn.Text = "← Back"
    $backBtn.Top = 590
    $backBtn.Left = 470
    $backBtn.Width = 80
    $backBtn.Height = 35
    $backBtn.Font = New-Object System.Drawing.Font("Segoe UI", 10)
    $backBtn.Add_Click({ $script:step = 3; Show-Step3 })
    $script:form.Controls.Add($backBtn)

    # Next Button
    $script:nextBtn = New-Object System.Windows.Forms.Button
    $script:nextBtn.Text = "Next →"
    $script:nextBtn.Top = 590
    $script:nextBtn.Left = 560
    $script:nextBtn.Width = 80
    $script:nextBtn.Height = 35
    $script:nextBtn.Font = New-Object System.Drawing.Font("Segoe UI", 10)
    $script:nextBtn.BackColor = [System.Drawing.Color]::LightBlue
    $script:nextBtn.Enabled = $false
    $script:nextBtn.Add_Click({ $script:step = 5; Show-Step5 })
    $script:form.Controls.Add($script:nextBtn)

    # Progress
    $progLabel = New-Object System.Windows.Forms.Label
    $progLabel.Text = "Step 4 of 5"
    $progLabel.Top = 595
    $progLabel.Left = 20
    $progLabel.Width = 200
    $progLabel.Height = 25
    $progLabel.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
    $script:form.Controls.Add($progLabel)

    $script:genBtn.Add_Click({
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
        if ($script:data.SetupEmail) {
            $script:data.MailuSecretKey      = Generate-SecurePassword 24
            $script:data.MailAdminPassword   = Generate-SecurePassword
        }
        $script:data.InfluxdbAdminPassword   = Generate-SecurePassword
        $script:data.InfluxdbAdminToken      = Generate-SecurePassword 32
        $script:data.GrafanaMainPassword     = Generate-SecurePassword
        $script:data.GotifyAdminPassword     = Generate-SecurePassword
        $script:data.VaultwardenAdminToken   = Generate-SecurePassword 32
        $script:data.ImmichDbPassword        = Generate-SecurePassword
        $script:data.PiholeWebPassword       = Generate-SecurePassword
        $script:data.ArrAuthPassword         = Generate-SecurePassword
        $script:data.RadicaleAuthPassword    = Generate-SecurePassword
        # Separate from ArrAuthPassword on purpose: qBittorrent controls what
        # gets downloaded (and, if abused, could leak download activity or
        # be pointed at unwanted content) - a materially worse outcome than
        # someone reaching the Arr apps' library management UI, so it isn't
        # worth sharing one login across both risk levels.
        $script:data.QbitAuthPassword        = Generate-SecurePassword

        $script:statusLabel.Text = "Generating secrets... hashing three of them via Docker, one moment"
        $script:statusLabel.Refresh()
        try {
            $script:data.ArrAuthHash      = Get-CaddyPasswordHash -PlainSecret $script:data.ArrAuthPassword
            $script:data.RadicaleAuthHash = Get-CaddyPasswordHash -PlainSecret $script:data.RadicaleAuthPassword
            $script:data.QbitAuthHash     = Get-CaddyPasswordHash -PlainSecret $script:data.QbitAuthPassword
        } catch {
            Show-Error "Failed to hash the Sonarr/Radarr/Radicale/qBittorrent passwords via Docker - is Docker Desktop running?`n`n$_"
            $script:statusLabel.Text = "Ready to generate"
            return
        }

        $secretCount = if ($script:data.SetupEmail) { 23 } else { 21 }
        $emailNote = if ($script:data.SetupEmail) { "" } else { "`n(Email server setup skipped - run _scripts\enable-email.ps1 later if that changes.)" }
        $script:statusLabel.Text = @"
✓ Generated $secretCount unique secrets (one per service/database - no reuse)
$emailNote
All passwords generated with a cryptographic RNG.
Click Next to review, then "Create .env Files".
"@
        $script:genBtn.Enabled = $false
        $script:genBtn.Text = "✓ Done"
        $script:nextBtn.Enabled = $true
    })
}

function Show-Step5 {

    $script:form.Controls.Clear()

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
    $script:form.Controls.Add($titleLabel)

    $descLabel = New-Object System.Windows.Forms.Label
    $descLabel.Text = "Review before creating .env files"
    $descLabel.Top = 55
    $descLabel.Left = 20
    $descLabel.Width = 600
    $descLabel.Height = 30
    $descLabel.Font = New-Object System.Drawing.Font("Segoe UI", 9)
    $descLabel.ForeColor = [System.Drawing.Color]::Gray
    $script:form.Controls.Add($descLabel)

    # Review Box
    $reviewBox = New-Object System.Windows.Forms.TextBox
    $reviewBox.Multiline = $true
    $reviewBox.ReadOnly = $true
    $reviewBox.ScrollBars = [System.Windows.Forms.ScrollBars]::Vertical
    $reviewBox.Top = 100
    $reviewBox.Left = 20
    $reviewBox.Width = 600
    $reviewBox.Height = 250
    $reviewBox.Font = New-Object System.Drawing.Font("Consolas", 9)

    $emailStatusText = if (-not $script:data.SetupEmail) {
        "Email server (Mailu): NOT set up now - email-stack\.env will not`nbe written. Run _scripts\enable-email.ps1 any time later to turn it on."
    } elseif ($script:data.MailDomain -eq $script:data.Domain) {
        "Mail Domain: $($script:data.MailDomain) (same as Domain)"
    } else {
        "Mail Domain: $($script:data.MailDomain) (separate from Domain - needs`nits own Cloudflare Public Hostname rules and DNS-edit permission too)"
    }
    $secretCountText = if ($script:data.SetupEmail) { "22 unique secure secrets" } else { "20 unique secure secrets" }
    $plexClaimText = if ([string]::IsNullOrEmpty($script:data.PlexToken)) {
        "Plex Claim Token: not set - claim it manually after deploying at`nhttp://<this-pc>:32400/web (sign in with your Plex account there)"
    } else {
        "Plex Claim Token: ✓ Set (only works if you finish this wizard AND`ndeploy within ~4 minutes of getting it - otherwise it'll expire, which`nis harmless, just means claiming it manually instead)"
    }

    $reviewBox.Text = @"
CONFIGURATION SUMMARY
═════════════════════════════════════════════

Domain: $($script:data.Domain)
$emailStatusText
Email: $($script:data.Email)
Timezone: $($script:data.Timezone)

Cloudflare API Token: ✓ Set
Cloudflare Tunnel Token: ✓ Set
(Reminder: the tunnel and its Public Hostname rules must already exist
in your Cloudflare dashboard - see SETUP.md if you haven't done that yet.)

ProtonVPN Username: $($script:data.ProtonUsername)
ProtonVPN Country: $($script:data.ProtonCountry)

Plex Domain: $($script:data.PlexDomain)
Jellyfin Domain: $($script:data.JellyfinDomain)
$plexClaimText

Passwords: ✓ Generated ($secretCountText)

═════════════════════════════════════════════
Click "Create .env Files" to proceed
"@
    $script:form.Controls.Add($reviewBox)

    # Auto-deploy checkbox - unchecked by default. This runs real,
    # consequential actions (creates host directories, pulls/builds Docker
    # images, starts every configured stack with real credentials), so it
    # stays opt-in rather than happening silently just because you clicked
    # "Create .env Files" - same reasoning as the email setup checkbox in
    # step 1.
    $script:autoDeployCheckbox = New-Object System.Windows.Forms.CheckBox
    $script:autoDeployCheckbox.Text = "Also run setup-directories.ps1, deploy.ps1, and health-check.ps1 now"
    $script:autoDeployCheckbox.Top = 360
    $script:autoDeployCheckbox.Left = 20
    $script:autoDeployCheckbox.Width = 560
    $script:autoDeployCheckbox.Height = 24
    $script:autoDeployCheckbox.Font = New-Object System.Drawing.Font("Segoe UI", 10)
    $script:autoDeployCheckbox.Checked = $false
    $script:form.Controls.Add($script:autoDeployCheckbox)

    $autoDeployInfoLabel = New-Object System.Windows.Forms.Label
    $autoDeployInfoLabel.Text = "Docker Desktop must already be running. Output prints in the PowerShell window this wizard was launched from - the first deploy takes a few minutes (builds a custom Caddy image), plus a short wait before checking health so containers have time to finish starting. Leave unchecked to review the .env files first and run those scripts yourself."
    $autoDeployInfoLabel.Top = 384
    $autoDeployInfoLabel.Left = 20
    $autoDeployInfoLabel.Width = 600
    $autoDeployInfoLabel.Height = 55
    $autoDeployInfoLabel.Font = New-Object System.Drawing.Font("Segoe UI", 8, [System.Drawing.FontStyle]::Italic)
    $autoDeployInfoLabel.ForeColor = [System.Drawing.Color]::Gray
    $script:form.Controls.Add($autoDeployInfoLabel)

    # Back Button
    $backBtn = New-Object System.Windows.Forms.Button
    $backBtn.Text = "← Back"
    $backBtn.Top = 590
    $backBtn.Left = 470
    $backBtn.Width = 80
    $backBtn.Height = 35
    $backBtn.Font = New-Object System.Drawing.Font("Segoe UI", 10)
    $backBtn.Add_Click({ $script:step = 4; Show-Step4 })
    $script:form.Controls.Add($backBtn)

    # Create Button
    $createBtn = New-Object System.Windows.Forms.Button
    $createBtn.Text = "✓ Create .env Files"
    $createBtn.Top = 590
    $createBtn.Left = 560
    $createBtn.Width = 80
    $createBtn.Height = 35
    $createBtn.Font = New-Object System.Drawing.Font("Segoe UI", 10)
    $createBtn.BackColor = [System.Drawing.Color]::LightGreen
    $createBtn.Add_Click({
        Create-EnvFiles
        $credPath = Export-Credentials
        $emailReminder = if ($script:data.SetupEmail) { "" } else { "`n`nEmail server (Mailu) setup was skipped - run .\enable-email.ps1 any time later to turn it on, no need to redo this wizard." }
        $credReminder = "`n`nA password-manager-ready credentials file was also written to:`n$credPath`n`nImport it as Bitwarden JSON - in Vaultwarden: Tools -> Import Data -> Bitwarden (json). In Proton Pass: Settings -> Import -> Bitwarden -> select this file (Proton Pass's Bitwarden importer only accepts JSON/ZIP, not CSV - confirmed live). Then delete that file - it's plaintext and not safe to leave sitting on disk."

        if ($script:autoDeployCheckbox.Checked) {
            # Runs on this same UI thread - the wizard window won't repaint
            # until these finish, same tradeoff Step 4's password generation
            # already makes for its own Docker calls. Their Write-Host
            # output goes to the console this wizard was launched from,
            # not this window, since neither script's output is designed
            # to be captured (deploy.ps1 also prints color-coded progress
            # that only makes sense as live console output).
            $createBtn.Enabled = $false
            $createBtn.Text = "Working..."
            $script:autoDeployCheckbox.Enabled = $false
            $script:form.Refresh()

            $deployFailed = $false
            $deployErrorDetail = ""
            $healthResultText = ""
            try {
                & "$appRoot\_scripts\setup-directories.ps1"
                & "$appRoot\_scripts\deploy.ps1" -Action deploy
                if ($LASTEXITCODE -ne 0) {
                    $deployFailed = $true
                    $deployErrorDetail = "deploy.ps1 exited with code $LASTEXITCODE - see the console window for which stack failed."
                } else {
                    # Most stacks deploy without waiting for a healthy state
                    # (see deploy.ps1's Deploy-Stack) - a short pause here
                    # before checking gives slower-starting containers
                    # (database init, first-run migrations, etc.) a chance
                    # to actually get there instead of reporting a false
                    # "unhealthy"/"starting" a few seconds after they began.
                    $createBtn.Text = "Waiting before health check..."
                    $script:form.Refresh()
                    Start-Sleep -Seconds 20

                    $createBtn.Text = "Checking health..."
                    $script:form.Refresh()
                    & "$appRoot\_scripts\health-check.ps1"
                    $healthResultText = if ($LASTEXITCODE -eq 0) {
                        "`n`nhealth-check.ps1: ✓ everything reported healthy."
                    } else {
                        "`n`nhealth-check.ps1 flagged something not yet healthy - see the console window for which service. Often just needs another minute or two (first-run database migrations, etc.) - re-run .\health-check.ps1 to check again."
                    }
                }
            } catch {
                $deployFailed = $true
                $deployErrorDetail = "$_"
            }

            if ($deployFailed) {
                Show-Error "The .env files were created fine, but deployment hit a problem:`n`n$deployErrorDetail`n`nFix the issue (check the console window this wizard was launched from for details), then run:`n.\deploy.ps1 -Action deploy`nyourself once it's resolved.$credReminder"
            } else {
                Show-Success "Success!`n`nAll .env files created, host directories set up, and every configured stack deployed.$healthResultText$emailReminder$credReminder"
            }
        } else {
            Show-Success "Success!`n`nAll .env files created.$emailReminder$credReminder`n`nNext:`n1. .\setup-directories.ps1`n2. .\deploy.ps1 -Action deploy`n3. .\health-check.ps1"
        }

        $script:form.Close()
    })
    $script:form.Controls.Add($createBtn)

    # Progress
    $progLabel = New-Object System.Windows.Forms.Label
    $progLabel.Text = "Step 5 of 5"
    $progLabel.Top = 595
    $progLabel.Left = 20
    $progLabel.Width = 200
    $progLabel.Height = 25
    $progLabel.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
    $script:form.Controls.Add($progLabel)
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
    # NOTE: must be the literal .Replace() string method, not the -replace
    # operator. -replace '\$','$$' looks right but silently does nothing:
    # PowerShell's -replace runs its replacement argument through .NET
    # regex substitution syntax, where '$$' is the ESCAPE SEQUENCE for a
    # single literal '$' - so '\$' -> '$$' round-trips to the same single
    # '$', a no-op. Confirmed live: every bcrypt hash written this way came
    # out un-doubled, which docker compose's own ${VAR} interpolation then
    # misread as a reference to a variable named after whatever alphanumeric
    # run followed the embedded '$' - silently deleting that whole chunk
    # from the hash before the container ever saw it. Every login gated by
    # arr_auth or radicale_auth was consequently unauthenticatable with ANY
    # password. .Replace() is a plain literal find-and-replace with no
    # substitution-pattern semantics, so it actually doubles the '$'.
    $arrAuthHashEscaped = $script:data.ArrAuthHash.Replace('$', '$$')
    $radicaleAuthHashEscaped = $script:data.RadicaleAuthHash.Replace('$', '$$')
    $qbitAuthHashEscaped = $script:data.QbitAuthHash.Replace('$', '$$')

    $mailDomainLine = if ($script:data.SetupEmail) {
        "# Same as DOMAIN unless you entered a separate Mail Domain in step 1 -`n# must match DOMAIN in email-stack\.env exactly either way.`nMAIL_DOMAIN=$($script:data.MailDomain)"
    } else {
        "# Email server setup was skipped - no email-stack\.env, so this has`n# nothing to match. Falls back to DOMAIN automatically if ever needed;`n# run _scripts\enable-email.ps1 to actually set Mailu up later."
    }

    $caddyEnv = @"
DOMAIN=$d
ACME_EMAIL=$($script:data.Email)
# Must match QBIT_PORT in media-stack\.env exactly.
QBIT_PORT=8080
CLOUDFLARE_API_TOKEN=$($script:data.CloudflareApiToken)
CLOUDFLARE_TUNNEL_TOKEN=$($script:data.CloudflareTunnelToken)
$mailDomainLine
# Shared login for Sonarr/Radarr/Prowlarr/Lidarr - see arr_auth in
# caddy/Caddyfile. Every `$` below is doubled deliberately - see comment
# above, don't "clean up" this into a single $.
ARR_AUTH_USER=admin
ARR_AUTH_HASH=$arrAuthHashEscaped
RADICALE_AUTH_USER=family
RADICALE_AUTH_HASH=$radicaleAuthHashEscaped
# Separate login from ARR_AUTH above on purpose - see qbit_auth in
# caddy/Caddyfile and the comment on QbitAuthPassword's generation.
QBIT_AUTH_USER=admin
QBIT_AUTH_HASH=$qbitAuthHashEscaped
"@
    $caddyEnv | Out-File "$appRoot\caddy\.env" -Encoding UTF8 -Force

    $mediaEnv = @"
PROTON_OPENVPN_USERNAME=$($script:data.ProtonUsername)
PROTON_OPENVPN_PASSWORD=$($script:data.ProtonPassword)
# Only needed if you set VPN_TYPE=wireguard below - leave blank for
# openvpn. gluetun tries to parse WIREGUARD_ADDRESSES as an IP whenever
# it's non-empty regardless of VPN_TYPE, so a placeholder string here
# (rather than genuinely blank) makes gluetun crash-loop even on openvpn.
PROTON_WIREGUARD_KEY=
PROTON_WIREGUARD_ADDRESSES=
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

    # No email-stack\.env at all when email setup was skipped: the stack
    # stays fully present in the repo (nothing removed, nothing to undo),
    # just unconfigured - deploy.ps1 skips any stack with no .env rather
    # than starting containers against empty variables. Run
    # _scripts\enable-email.ps1 to write this file later without
    # re-running the whole wizard.
    if ($script:data.SetupEmail) {
        $emailEnv = @"
# Same as caddy\.env's MAIL_DOMAIN - must match exactly.
DOMAIN=$($script:data.MailDomain)
MAILU_SECRET_KEY=$($script:data.MailuSecretKey)
MAIL_ADMIN_USER=admin
MAIL_ADMIN_PASSWORD=$($script:data.MailAdminPassword)
TZ=$($script:data.Timezone)
"@
        $emailEnv | Out-File "$appRoot\email-stack\.env" -Encoding UTF8 -Force
    }

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
    # one Bitwarden-format JSON file - Vaultwarden speaks it natively, and
    # it's the only Bitwarden format Proton Pass's "Bitwarden" importer
    # actually accepts (its CSV path only takes Proton Pass's own CSV
    # schema, confirmed live - a Bitwarden-schema CSV silently imports
    # names with no username/password, since Proton Pass's *generic* CSV
    # importer has no idea those columns mean anything). This is the file
    # SECURITY.md means by "back up your secrets" - it's plaintext,
    # gitignored, and meant to be imported and then deleted, not kept
    # sitting on disk.
    $d = $script:data.Domain
    $md = $script:data.MailDomain
    # Not List[PSCustomObject]: New-CredRow below returns an [ordered]
    # hashtable (needed for ConvertTo-Json's key ordering), which a
    # strictly-typed PSCustomObject list would reject.
    $rows = [System.Collections.Generic.List[object]]::new()

    function New-CredRow {
        # $Uri accepts either one URL or an array of them - a shared login
        # (the Arr stack's basic-auth, for example) works across several
        # subdomains, and listing all of them here is what lets Bitwarden/
        # Proton Pass autofill on every one of those sites, not just the
        # first.
        param([string]$Name, $Uri = @(), [string]$Login = "", [string]$Secret = "", [string]$Notes = "")
        # uris MUST be built as an ArrayList, not a bare @() array literal
        # assigned through an if/else - PowerShell's if/else statement
        # unwraps a single-element array result down to its bare element
        # during assignment (confirmed live: $x = if(...){@()}else{@(one
        # item)} left $x as a plain Hashtable, not an array), which
        # ConvertTo-Json then serializes as a JSON object instead of a
        # one-element array - silently violating Bitwarden's schema.
        $uris = [System.Collections.ArrayList]::new()
        foreach ($u in @($Uri)) {
            if (-not [string]::IsNullOrEmpty($u)) { [void]$uris.Add(@{ match = $null; uri = $u }) }
        }
        [ordered]@{
            id             = [guid]::NewGuid().ToString()
            organizationId = $null
            folderId       = $script:credFolderId
            type           = 1
            reprompt       = 0
            name           = $Name
            notes          = if ([string]::IsNullOrEmpty($Notes)) { $null } else { $Notes }
            favorite       = $false
            login          = [ordered]@{
                username = if ([string]::IsNullOrEmpty($Login)) { $null } else { $Login }
                password = if ([string]::IsNullOrEmpty($Secret)) { $null } else { $Secret }
                totp     = $null
                uris     = $uris
            }
            collectionIds  = $null
        }
    }

    $script:credFolderId = [guid]::NewGuid().ToString()

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
    if ($script:data.SetupEmail) {
        $rows.Add((New-CredRow "Mailu Admin / Webmail" "https://mailadmin.$md" "admin" $script:data.MailAdminPassword "Same login also works at webmail.$md"))
        $rows.Add((New-CredRow "Mailu Secret Key" "" "" $script:data.MailuSecretKey "Internal session-signing key, not a login password"))
    }
    $rows.Add((New-CredRow "InfluxDB Admin" "" "admin" $script:data.InfluxdbAdminPassword "No direct web route published - reached via Grafana"))
    $rows.Add((New-CredRow "InfluxDB API Token" "" "" $script:data.InfluxdbAdminToken "API token, not a login password"))
    $rows.Add((New-CredRow "Grafana" "https://grafana.$d" "admin" $script:data.GrafanaMainPassword ""))
    $rows.Add((New-CredRow "Gotify" "https://gotify.$d" "admin" $script:data.GotifyAdminPassword ""))
    $rows.Add((New-CredRow "Vaultwarden Admin Panel" "https://vault.$d/admin" "" $script:data.VaultwardenAdminToken "Token-based admin panel login, no username"))
    $rows.Add((New-CredRow "Immich Database" "" "postgres" $script:data.ImmichDbPassword "Internal Postgres password - not a login page"))
    $rows.Add((New-CredRow "Pi-hole" "https://pihole.$d" "" $script:data.PiholeWebPassword "Password-only login, no username"))
    $rows.Add((New-CredRow "Sonarr / Radarr / Prowlarr / Lidarr" @("https://sonarr.$d", "https://radarr.$d", "https://prowlarr.$d", "https://lidarr.$d") "admin" $script:data.ArrAuthPassword "Shared Caddy basic-auth login - autofills on all four sites"))
    $rows.Add((New-CredRow "qBittorrent" "https://qbit.$d" "admin" $script:data.QbitAuthPassword "Caddy basic-auth in front of qBittorrent's WebUI - deliberately a separate login from the Arr stack above. qBittorrent's OWN WebUI login (Tools > Options > Web UI) is separate again and defaults to a random temporary password printed in its container logs on first start - set a permanent one there too the first time you log in."))
    $rows.Add((New-CredRow "Radicale (Calendar/Contacts)" "https://cal.$d" "family" $script:data.RadicaleAuthPassword "Caddy basic-auth in front of Radicale, which has no auth of its own"))
    $rows.Add((New-CredRow "ProtonVPN" "https://account.protonvpn.com" $script:data.ProtonUsername $script:data.ProtonPassword "Used by media-stack's gluetun VPN routing"))
    $rows.Add((New-CredRow "Portainer" "https://portainer.$d" "" "" "Set your own password on first visit, then fill in here"))
    $rows.Add((New-CredRow "Trilium" "https://notes.$d" "" "" "Set your own password on first visit, then fill in here"))
    $rows.Add((New-CredRow "Focalboard" "https://boards.$d" "" "" "Set your own password on first visit, then fill in here"))
    $rows.Add((New-CredRow "Jellyfin" "https://jellyfin.$d" "" "" "Set your own admin account on first visit, then fill in here"))

    $export = [ordered]@{
        encrypted = $false
        folders   = @($([ordered]@{ id = $script:credFolderId; name = "Homelab" }))
        items     = $rows
    }

    $exportPath = "$appRoot\credentials-export.json"
    $export | ConvertTo-Json -Depth 6 | Out-File $exportPath -Encoding UTF8 -Force
    return $exportPath
}

$script:form = Create-Form
Show-Step1
$script:form.ShowDialog() | Out-Null
