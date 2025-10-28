# irc.libera.chat 
# Channel: #OpenBSD 
# Author: ssm_
# Question: Is recommended to use Fail2ban or PF <tables> are enought? 
# Mind Blowing Answer!!!! 
man pf.conf | col -b | awk '$1=="max-src-conn"{n++}/^$/{if(n>0)n++}{if(n>0&&n<7)print}'
