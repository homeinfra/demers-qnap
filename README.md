# demers-qnap

Configuration code for the Demers machine called qnap. The hardware is actually a QNAP TVS-663 running XCP-ng 8.3

The server can be configured by calling this one-liner:
```bash
wget -qO - 'https://raw.githubusercontent.com/jeremfg/setup/refs/heads/feature/linux-setup/src/setup_git.sh' | bash -s git@github.com:homeinfra/demers-qnap.git feature/initial -- ./src/setup.sh
```
Please note, that you need to configure SSH credentials for your github account first. [This is explained here](https://docs.github.com/fr/authentication/connecting-to-github-with-ssh/generating-a-new-ssh-key-and-adding-it-to-the-ssh-agent?platform=linux).
