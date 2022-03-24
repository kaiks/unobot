# unobot
A bot that intelligently plays irc variant on the uno card game

Required gems:
cinch
sequel

Tested on jruby

The uno game can be found in ZbojeiJureq repository (uno_plugin.rb and related files)

### Running on docker

```
docker build . -t unobot
docker run -e TZ=Europe/Berlin --mount source=logs,target=/unobot/logs -p 6667:6667 -it unobot
```

the config on windows and mac has to refer to host.docker.internal as opposed to localhost