# Bonus ANSSI R36 : un fichier créé dans un shell n'est lisible que par son
# propriétaire. Les ACL par défaut de /srv ne sont pas concernées par l'umask.
umask 077
