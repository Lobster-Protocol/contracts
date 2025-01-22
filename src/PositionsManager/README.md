# Lobster Contracts - Positions Manager
The Position Manager contracts is responsible for retrieving the vault's value (in eth) across protocols (on the same chain). 
When a withdraw is requested, it is also responsible for safely unwinding the position and returning the funds to the vault (should avoid liquidations and too much unbalance depending on the Lobster algorithm).