#!/bin/bash

echo "Don't forget to add the first user!\n"
read -p "Username (press enter to use 'firstuser' as username): " username
if [ -z "$username" ]; then 
    username="firstuser"
fi

useraddress="$username@$MAILDOMAIN"
read -p "Password (press enter to generate random): " password
if [ -z "$password" ]; then 
    password=`head /dev/urandom | tr -dc A-Za-z0-9 | head -c30` # random password
    echo -e "Your generated password: $password"
fi

echo -e "Your first user:\nUsername: $username\nPassword: $password\nAddress:$useraddress\n"

curl -i -XPOST http://localhost:8080/users \
-H 'Content-type: application/json' \
-H "X-Access-Token: $ACCESS_TOKEN" \
-d '{"username": '\"$username\"', "password": '\"$password\"', "address": '\"$useraddress\"'}'

echo "All done, open https://$HOSTNAME/ in your browser"