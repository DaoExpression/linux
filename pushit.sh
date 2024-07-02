#!/bin/bash
# Author: Imagine You Selfs 
# 2023
git add .
git  commit -m "Make it right for a better ride"
pkill -x ssh-agent 
sleep 1
eval $(ssh-agent)
sleep 1 
ssh-add ~/.ssh/github
sleep 1
git push git@github.com:DaoExpression/vim
