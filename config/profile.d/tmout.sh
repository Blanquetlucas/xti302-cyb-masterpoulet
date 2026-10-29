# S4 : déconnexion d'un shell inactif au bout de 10 minutes.
# readonly pour qu'un utilisateur ne puisse pas faire "unset TMOUT" ; le test
# évite l'erreur si le fichier est lu deux fois dans le même shell.
if [ "${TMOUT:-}" != 600 ]; then
    TMOUT=600
    readonly TMOUT
    export TMOUT
fi
