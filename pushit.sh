#!/bin/bash
# Author: Imagine You Selfs 
# 2023
pkill -x ssh-agent 
sleep 1
eval $(ssh-agent)
sleep 1 
ssh-add ~/.ssh/github_rsa
sleep 1
git push git@github.com:imagineyourselfs/vim-files
clear
