# RouterOS 7: second full-admin account, so one forgotten or locked password is not a lockout.
# Replace the password before running. Avoid $ \ ? and " in it: the RouterOS command line
# treats $ as a variable and \ as an escape, so the stored password would differ from yours.
# Test from a second SSH session before logging out of the first.
/user add name=netadmin group=full comment="break-glass admin" password="CHANGE-ME-letters-and-digits-only"
/user print
