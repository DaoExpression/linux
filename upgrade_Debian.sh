#!/bin/bash 
# Oscar FM 
# odicforcesounds.com 

sudo sed -i 's/bookworm/trixie/g' /etc/apt/sources.list
sudo find /etc/apt/sources.list.d -type f -exec sed -i 's/bookworm/trixie/g' {} \;
sudo apt update && sudo apt full-upgrade
sudo reboot 

sudo apt modernize-sources
sudo apt autoremove --purge && sudo apt clean 

