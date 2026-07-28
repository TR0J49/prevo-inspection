=======================================================================
  NSDL WORKSTATION COMPLIANCE AUDIT - USB INSTALLER
  Instructions for the IT Manager
=======================================================================

WHAT THIS DOES
--------------
Installs an automatic audit on a workstation. After installation the PC
audits itself every few hours and after every startup, and sends the
result to the audit server. Nobody has to run anything again.

Takes about 2 minutes per PC. One visit per PC, permanently.


-----------------------------------------------------------------------
  STEP 1 - PREPARE THE USB (do this ONCE, before you start)
-----------------------------------------------------------------------

1. Copy this whole "installer" folder onto the USB stick.

2. Open  config.txt  in Notepad and set:

      SERVER_URL=http://<server-ip>:8000

   Use the server's NETWORK ip address, NOT localhost and NOT 127.0.0.1.
   The workstation has to reach the server across the network.

   To find it: on the audit server, look at the startup message -
       Network : http://192.168.1.45:8000

3. Optionally change how often the audit runs:

      INTERVAL_HOURS=3

4. Save the file. The USB is now ready for every PC, in every branch.

   IMPORTANT: give the server a FIXED ip first - a DHCP reservation on
   the router, and a wired connection. If the server ip changes, every
   installed PC stops reporting and has to be visited again.


-----------------------------------------------------------------------
  STEP 2 - INSTALL ON A WINDOWS PC
-----------------------------------------------------------------------

1. Plug in the USB.
2. Open the  windows  folder.
3. RIGHT-CLICK  Install-Audit.bat  ->  "Run as administrator".
4. If a blue "Windows protected your PC" box appears:
       click "More info"  ->  "Run anyway"
   (this happens because the file came from a USB, it is expected)
5. Wait for "SETUP COMPLETE". Note the Device id shown.
6. Close the window. Done - remove the USB.

To remove later:
   right-click  uninstall-audit.ps1  ->  "Run with PowerShell"  as admin


-----------------------------------------------------------------------
  STEP 3 - INSTALL ON A MAC
-----------------------------------------------------------------------

1. Plug in the USB.
2. Open the  macos  folder.
3. RIGHT-CLICK  install-audit.command  ->  "Open"
       (right-click "Open", NOT double-click - macOS blocks files from a
        USB on the first run. Choosing "Open" gives you the Open button.)
4. If it still refuses to run, open Terminal and type:
       sudo bash /Volumes/<USB-NAME>/installer/macos/install-audit.command
5. Enter the Mac password when asked.
6. Wait for "SETUP COMPLETE". Note the Device id.

To remove later:  right-click  uninstall-audit.command  ->  "Open"


-----------------------------------------------------------------------
  STEP 4 - INSTALL ON A LINUX PC
-----------------------------------------------------------------------

1. Plug in the USB, open a Terminal.
2. Go to the linux folder on the USB, for example:
       cd /media/$USER/<USB-NAME>/installer/linux
3. Run:
       sudo bash install-audit.sh
4. Enter the password when asked.
5. Wait for "SETUP COMPLETE".

To remove later:  sudo bash uninstall-audit.sh


-----------------------------------------------------------------------
  STEP 5 - CHECK IT WORKED
-----------------------------------------------------------------------

On the audit server, open the dashboard and go to "Device Audits".
Click "Refresh Devices". The PC you just set up should be listed with
today's date and time.

If it is not there, see TROUBLESHOOTING below.


-----------------------------------------------------------------------
  TROUBLESHOOTING
-----------------------------------------------------------------------

"Cannot reach <server>"
   - The server is not running, or
   - SERVER_URL is wrong (must be the network ip, not localhost), or
   - the PC is on a different network / Wi-Fi, or
   - the server firewall is blocking the port.
   Test from the PC: open a browser and visit the SERVER_URL. You should
   see the audit dashboard.

"This installer must run as Administrator"
   - You double-clicked instead of right-click "Run as administrator".

Mac refuses to open the file
   - Right-click the file and choose "Open" (do not double-click).
   - Or run it from Terminal with sudo, as shown in Step 3.

Nothing appears in the dashboard after installing
   - Look at the log on the PC:
         Windows : C:\ProgramData\NSDLAudit\audit.log
         Mac     : /Library/Application Support/NSDLAudit/audit.log
         Linux   : /var/lib/nsdl-audit/audit.log

To check the schedule exists
   Windows : open Task Scheduler, look for "NSDL Compliance Audit"
   Mac     : sudo launchctl list | grep nsdl
   Linux   : systemctl status nsdl-audit.timer

To force an audit immediately (for testing)
   Windows : schtasks /Run /TN "NSDL Compliance Audit"
   Mac     : sudo launchctl kickstart -k system/com.nsdl.audit
   Linux   : sudo systemctl start nsdl-audit.service


-----------------------------------------------------------------------
  NOTES
-----------------------------------------------------------------------

* Re-running the installer on the same PC is safe. It keeps the same
  Device id, so the PC's audit history is not broken.

* Each PC gets a permanent Device id, stored on that PC. This is how the
  server recognises the same machine across audits.

* Each scheduled run downloads the newest audit script from the server.
  So if a collection bug is fixed on the server, every PC picks it up
  automatically on its next run - no need to revisit the machines.

* Runs are spread out by a random delay of up to 5 minutes so that all
  PCs in a branch do not contact the server at the same instant.

* The audit does not read documents, email or personal files. It records
  hardware, installed software, printers and login history only.
