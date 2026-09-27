# RouterOS 7: clear the log buffers, including the critical messages shown at every login.
# RouterOS has no "clear log" command. Shrinking a store to 1 line empties it, then it is set back.
# 'critical' goes to the echo store by default, which only keeps messages while remember=yes.
/system logging action set echo remember=no
/system logging action set echo remember=yes
/system logging action set memory memory-lines=1
/system logging action set memory memory-lines=1000
