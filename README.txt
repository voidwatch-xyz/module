Voidwatch module and upload scripts                                          MIT licence

1. Close the game client.
2. Copy the "voidwatch" folder into the modules folder of your client: the folder that holds the
   other modules (the ones named game_... and client_...).
3. Set up the upload script once, by double-clicking:
     Windows:  setup-windows.cmd
     macOS:    setup-mac.command   (the first time: right-click it, pick Open, then Open again)
     Linux:    sh setup-linux.sh
   It runs in the background and starts at every login from then on. A client that runs through Wine or
   CrossOver uses the macOS or Linux setup.
4. Start the client and log in. A game message shows a code and a link. Open the link to try the
   dashboard as a guest, or type the code in Settings, Clients on the website.

If the game message says the setup did not find the client, drop the folder it shows onto the setup file
(Windows) or drag it into the setup window (macOS), or run: sh setup-linux.sh "<folder>".

To remove the upload script: remove-windows.cmd, remove-mac.command or sh remove-linux.sh.

Adapting the module to a server: https://voidwatch.xyz/developers/new-server
