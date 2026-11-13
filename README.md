# local-website-blocker

**Windows Website Blocker**

A lightweight local batch script that leverages Windows Defender to block websites on Windows. It runs locally and offline. 

**Setup & Usage:**
1. Download the .bat file.
2. Double-click the file to run it (note: administrator privileges are required).
3. Type the domain of the website you want to block (e.g., example.com).
4. Follow the on-screen prompts in the command window to finish setup.

**Master Key / Reset:**
To remove all website blocks immediately, regardless of whether they are currently locked or unlocked, run the .bat and type:

> EXODUS

This will clear all rules and restore your system to its default settings.

**Uninstallation:**
1. Run the script and enter the EXODUS master key to clear all active blocks.
2. Delete the .bat file from your computer.

**DISCLAIMER: RUN AT YOUR OWN RISK.**

I built this tool for personal use, and since I am the only real-world tester, YOU may run into unforeseen edge cases before I do. 
If you find a bug, please email me at **peppereddd@gmail.com** with the steps to reproduce the issue so I can test it and push a fix.

**AI Disclosure:**

> 20%-30% of the end-product code was generated using AI. AI was used in the process only to troubleshoot and identify edge-cases and bugs in advance.
