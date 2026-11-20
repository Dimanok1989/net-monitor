# Network connection monitor

[Русская версия](../README.md)

A Windows and Linux utility that watches which programs open TCP connections and writes the remote addresses to text logs. Each application gets its own file for the current date.

## Start

### Windows

Double-click `start-monitor.bat`.

The file asks for administrator rights. Accept the prompt so the monitor can see every process, the executable path, and names from the system DNS cache. If you decline, monitoring still starts with the current user's rights.

The window stays open and appends new addresses until you press Ctrl+C.

Running it again on the same day continues the same files and does not repeat addresses already recorded. A second window will not start while the first one is running.

### Linux

```sh
chmod +x net-monitor.sh
./net-monitor.sh
```

The script asks for `sudo` so it can see every application and its path. If root is declined, monitoring continues as the current user. Stop it with Ctrl+C.

Poll interval, in seconds:

```sh
./net-monitor.sh --interval 5
```

## Where logs are written

The `logs` directory is created next to the script. The file name is the application name and the date:

```text
logs\chrome_2026-11-20.log
logs\dbeaver_2026-11-20.log
```

For `svchost.exe`, the service name from the command line is added, for example `svchost_Dnscache_2026-11-20.log`.

## File format

```text
# dbeaver
# C:\Program Files\DBeaver\dbeaver.exe
192.168.1.10:5432
192.168.1.20:22    fileserver.local
```

The first line is the application name, the second is the path to the executable. If the path is unavailable, the line is `# (путь недоступен)`. Below that is the list of remote addresses: `IP:port`, then the domain when it is known. IPv6 is written in brackets: `[2001:db8::1]:443`.

The same address is stored once per day. If a line is first written with only the IP, the domain is added to that line as soon as it is resolved.

## How it works

Every 2 seconds the script reads the TCP connection table and matches connections to processes. Windows uses `netstat`, Linux uses `ss`. The log receives the remote address of a connection the application opened itself. Listening ports and incoming connections to them are omitted. Loopback addresses (`127.0.0.1`, `::1`) are omitted as well.

On Windows the domain comes from the DNS cache, then from reverse DNS if the cache has no record. On Linux the name comes from the system resolver (`getent`). A cache name is closer to the name the program requested. A reverse name may belong to a hoster or a CDN and can appear on the line a few seconds after the address.

## Parameters

Change the poll interval by passing it to the script. The value is in seconds, from 1 to 3600:

```bat
start-monitor.bat -IntervalSeconds 5
```

The same parameter works when starting the script directly:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\net-monitor.ps1 -IntervalSeconds 5
```

Windows PowerShell 5.1 is required. It is already included in Windows 10 and Windows 11.

On Linux the interval is the `--interval` flag. The script needs `ss` (iproute2), `flock` (util-linux), and `getent`.

## Limitations

- Only TCP connections are recorded. The connection table does not include a destination address for UDP.
- A connection shorter than the poll interval can be missed.
- The domain does not always match the name typed in the program: the shared DNS cache and reverse DNS are not tied to that application's request.
- Only one monitor window runs at a time.
