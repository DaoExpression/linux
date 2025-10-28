#!/bin/bash 
# READ 
# 1. Generate in your machine a ssh-key for this connection
# 2. Add that key and upload it to server 
# -- ssh-copy-id -i ~/.ssh/server USER@greatsky.ddns.net 
# 3. Connect to server without using a Password 

ssh -i ~/.ssh/server 'app@greatsky.ddns.net'

