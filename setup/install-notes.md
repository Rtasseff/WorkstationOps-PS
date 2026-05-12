# Install Notes — WorkstationOps (Windows)

## Prerequisites

- **Windows 10/11** with WSL2 enabled
- **PowerShell 5.1+** (ships with Windows 10/11) or PowerShell 7+
- **Network drive K:** mapped to the backup target
- **WSL distro** registered (e.g., Ubuntu from Microsoft Store)

## Execution policy

PowerShell scripts are blocked by default. Set the execution policy for the current user:

```powershell
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser
```

Or run individual scripts with bypass:

```powershell
powershell -ExecutionPolicy Bypass -File .\ops.ps1 verify
```

## Mapping the K: drive

If K: is not already mapped:

```powershell
# Map network drive (persistent across reboots)
New-PSDrive -Name K -PSProvider FileSystem -Root \\server\share -Persist

# Or via net use
net use K: \\server\share /persistent:yes
```

## First-time setup

```powershell
# 1. Clone or copy WorkstationOps to your machine
# 2. Verify everything is in order
.\ops verify

# 3. Create the scheduled task
.\ops schedule

# 4. (Optional) Run a dry-run to see what would happen
.\ops run wsl-backup --dry-run

# 5. Run the first backup
.\ops run wsl-backup
```

## Rebuilding WSL from a backup

If you need to rebuild from scratch (new machine, corrupted WSL, etc.):

```powershell
# 1. Enable WSL if not already
wsl --install --no-distribution

# 2. Import the backup
#    Choose where to store the new ext4.vhdx
wsl --import Ubuntu C:\Users\rtasseff\WSL\Ubuntu D:\backup\wsl-gold\wsl-ubuntu-2026-02-01.tar

# 3. Set default user
ubuntu config --default-user rtasseff

# 4. (Optional) Set as default distro
wsl --set-default Ubuntu

# 5. Verify
wsl -d Ubuntu
```

## Rebuilding from scratch (no backup)

```powershell
# 1. Install Ubuntu from Microsoft Store, or:
wsl --install -d Ubuntu

# 2. Set up your user account (first launch wizard)

# 3. Inside WSL, restore your dotfiles and WorkstationOps:
#    git clone <your-dotfiles-repo>
#    git clone <your-workstationops-repo>

# 4. Re-run any setup scripts from your WSL WorkstationOps project
```

## Task Scheduler troubleshooting

- Open Task Scheduler: `taskschd.msc`
- Look for task named `WorkstationOps-WSL-Backup`
- The task runs only when the user is logged on (so the notification is visible)
- If the task missed its schedule, it will run at the next opportunity
- Manual run: right-click the task and select "Run"
