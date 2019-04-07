---
layout: post
title: Setup a Mac OSX for development purposes 
comments: true
---

Tools to setup:
* brew
* git
* Intellij

#### 1 - Open a terminal & Install brew
https://brew.sh

`$ /usr/bin/ruby -e "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/master/install)"`

See docs?
https://docs.brew.sh

#### 2 - Lets now test that brew is working to install git using brew

`$ brew install git`

Is it working?   git status
joeys-MacBook-Pro:workspaces joey$ git status
fatal: not a git repository (or any of the parent directories): .git

Good!

#### 3 - Download a IDE (Intellij)
https://www.jetbrains.com/idea/download/#section=mac
But oh no, Intellij is looking for a JDK for us??

#### 4 - Downlad a JDK; lets use homebrew for this. In my case I need JDK 8 which is not the latest version.
So, we will use casks for this.

`$ brew tap caskroom/versions`

`$ brew update`

`$ brew cask install java8`

For latest Java:

`$ brew cask install java`

test its working:
joeys-MacBook-Pro:workspaces joey$ java -version
java version "1.8.0_202"
Java(TM) SE Runtime Environment (build 1.8.0_202-b08)
Java HotSpot(TM) 64-Bit Server VM (build 25.202-b08, mixed mode)

#### 5 - Set up SSH connection to GIT
https://help.github.com/en/articles/generating-a-new-ssh-key-and-adding-it-to-the-ssh-agent
$ ssh-keygen -t rsa -b 4096 -C "joeyfaherty@live.ie"

`$ cat ~/.ssh/id_rsa.pub`

paste the output into 
https://github.com/settings/keys


Enable GIT CLI auto-complete (very useful)

`$ curl https://raw.githubusercontent.com/git/git/master/contrib/completion/git-completion.bash -o ~/.git-completion.bash`

This will download this file in your home folder.
Then, set up your `~/.bash_profile` to use this file and also some other useful things.


Create a `.bash_profile` under your home directory `~/.bash_profile` 

This is an example of a basic `.bash_profile` of mine
```concept
# settings for your terminal prompt
export PS1='$(whoami)@macbook:`basename $PWD` $'

# uses the git-completion file in your home directory downloaded from here [curl https://raw.githubusercontent.com/git/git/master/contrib/completion/git-completion.bash -o ~/.git-completion.bash
if [ -f ~/.git-completion.bash ]; then
  . ~/.git-completion.bash
fi

alias ll='ls -altr'

alias dockrrm='docker rm -f $(docker ps -aq)'

JAVA_HOME=/Library/Java/JavaVirtualMachines/jdk1.8.0_144.jdk/Contents/Home
export JAVA_HOME

#PATH=$JAVA_HOME:$M3_HOME:/bin$PATH
PATH=/usr/local/bin:$JAVA_HOME:$PATH
export PATH
```

Run source on the file to active it
`$ source ~/.bash_profile`

 




