# Insomnia for Intel Macs (macOS 12 and later)

Keeps this Mac running with the lid closed, so cloud sessions, downloads and
agents keep working. Built for an Intel MacBook on macOS 15, because none of
these five repos run there:

| Repo | What it is | Why not usable here |
|---|---|---|
| semaja2/insomniax | Original InsomniaX (2015) | Archived, needs an unsigned kernel extension; dead on macOS 11+ |
| AxonDragonScale/Insomnia | Swift menu bar timer | Only blocks *idle* sleep (like `caffeinate`); the lid still sleeps the Mac |
| mdblack98/Insomnia | USB keep-alive utility | Unrelated to Mac sleep |
| vorssaint/vorssaint-utils | Big menu bar toolkit with "Keep awake" | Apple Silicon only |
| krishhgg/Insomnia | Best design: timed lid-closed sessions with recovery | Apple Silicon + macOS 26 + Swift 6.2 only |

krishhgg/Insomnia and Vorssaint both work by flipping macOS's own
`pmset disablesleep` bit. This folder does the same thing natively, with the
same safety ideas (sudoers rule limited to two commands, a once-a-minute
recovery agent, a battery floor).

## Install

Needs only the Xcode Command Line Tools (`xcode-select --install`).

```bash
git clone https://github.com/professer-create/insomnia-mac.git
cd insomnia-mac
./install.sh
```

The installer ends by printing one `sudo install ...` command. Run it once with
your Mac password, then `insomnia on` or click the eye in the menu bar.

## What gets installed

- `/usr/local/bin/insomnia`: the command line tool.
- `~/Applications/Insomnia.app`: eye icon in the menu bar (built from `MenuBar/main.swift`).
- `~/Library/LaunchAgents/com.usman.insomnia.backstop.plist`: runs `insomnia backstop` every minute.
- `~/Library/LaunchAgents/com.usman.insomnia.menubar.plist`: starts the menu bar app at login.
- `/etc/sudoers.d/insomnia`: **you install this one with your password.** It lets your
  user run exactly `/usr/bin/pmset -a disablesleep 1` and `... 0` without a password.

## Use

```bash
insomnia on          # stay awake until you say otherwise
insomnia on 8h       # stay awake for 8 hours
insomnia off         # normal sleep again
insomnia status
```

Or click the eye in the menu bar.

## Lock on lid close

With sleep disabled, closing the lid no longer locks the screen by itself,
so anyone could open the lid and use the Mac. The menu bar app watches the
lid through IOKit and, when it closes, locks the screen the same way
Control-Command-Q does (processes keep running; opening the lid shows the
password screen). It is on by default; "Lock Screen When Lid Closes" in the
menu turns it off, for example while using an external display in clamshell
mode. "Lock Screen Now" (Command-L in the menu) tests it.

## Network guard

An awake Mac can still lose Wi-Fi: on an Intel MacBook the link sometimes
drops while the display is off and nothing is using it, and macOS can sit
unassociated for minutes before it rejoins. While a session is on, the
`com.usman.insomnia.netguard` agent pings the router every 5 seconds (which
also keeps the link from idling). If nothing answers for 30 seconds it turns
Wi-Fi off and on, which forces a fresh join and DHCP lease; it retries every
minute, then every 5 minutes. Everything is written to
`~/Library/Logs/Insomnia/netguard.log`, and `insomnia status` shows the last
lines. It needs no password: `networksetup -setairportpower` works for an
admin user.

## Safety

- Keep the Mac on a desk or stand while the lid is closed, never in a bag.
- On battery, the session ends automatically at 10% (`INSOMNIA_BATTERY_FLOOR` changes it).
- A timed session ends on time even if the menu bar app is not running.
- `./uninstall.sh` removes everything and prints the one `sudo rm` for the sudoers file.
