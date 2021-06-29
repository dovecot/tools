#!/usr/local/bin/perl
#
# usage: procmail2sieve <path to .procmailrc>
#
# A simple procmailrc (including piping into vacation) to Sieve conversion script.
#
# This version can handle simple matches (with regex), acting on a copy or inline,
# sending to a folder, redirection and piping into vacation. It can't handle nested
# match rules or anything very complex.
#
# The script will filter the given .procmailrc and, if required, look in the same
# directory for a .vacation.msg file and output the Sieve equivalent to standard output.
#
# Note: This will only work with Sieve interpretors with implement the regex, envelope and
#       vacation extensions, e.g. the Dovecot-Sieve plugin.
#

$domain="my.mail.domain.com";

die("usage: $0 procmailrc\n") if (scalar(@ARGV) == 0);

$filename = $ARGV[0];

@filepath = split('/', $filename);
$#filepath = $#filepath - 1;

$homedir = '/'.join('/', @filepath);

open(PROCMAILRC, "<$filename") || die("Can't open $filename\n");

$copy = 0;
$valid = 0;
$filed = 0;

print "# Sieve Filter\n\nrequire [\"fileinto\",\"regex\",\"envelope\",\"vacation\"];\n\n"; 

while(<PROCMAILRC>)
{
	chomp;

# Junk comment lines and empty lines.	
	next if (/^#/);
	next if (/^\s*$/);

# Is it the start of a recipe?
	if (/^:0/)
	{
# If we have previously been processing a recipe finish it off and output the converted version.
		if (($#matches >= 0) && ($valid > 0))
		{
			print join("\n", @matches), "\n";
			if (scalar(@actions) >= 0)
			{
				print "\t", join(";\n\t", @actions), ";\n";

				print "\tdiscard;\n" if (($copy == 0) && ($filed == 0));
				print "}\n\n";
			}
			$filed = 0;
		}
# Determine if we are to be acting on a copy of the message.
		if (/c/)
		{
			$copy = 1;
		}
		else
		{
			$copy = 0;
		}
# Clear out all the matches and actions from the previous recipe.
		@matches = ();
		@actions = ();
		next;
	}

# Is it a match line?
	if (/^\*/)
	{
		$valid++;
		$regex = 0;
		$test = 'if';

		@match = split;
		shift @match;

# Extract the header name from the rest of the line.
		$headername = shift @match;
		$match = join(' ', @match);

# Is the extracted term really a header? If not, assume it's a an unconditional recipe.
		$header = (($headername =~ /\^/)? 1 : 0);
		$headername =~ s/\^//;
# Is it in the envelope or the body?
		if ($headername =~ /:/)
		{
			$header = 2;
			$headername =~ s/://;
		}
# Do we have a regex on our hands?
		if ($match =~ /[\[\(\*\.]/)
		{
			$regex = 1;
			$match =~ s/\\/\\\\/g;
		}

		if ($header)
		{
			if ($header == 1)
			{
				$test = "$test envelope ".($regex ? ':regex ' : '');
			}
			else
			{
				$test = "$test header ".($regex ? ':regex ' : '');
			}
			$matches[scalar(@matches)] = $test.':comparator "i;octet" '.($regex ? '' : ':contains').' "'.$headername.'" "'.$match.'" {';
		}
		else
		{
			$matches[scalar(@matches)] = 'if true {';
		}
		$filed = 1;
		next;
	}

# Is it a redirection?
	if (/^!/)
	{
		$valid++;
		@forward = split;
		shift @forward;
		$actions[scalar(@actions)] = "redirect \"".join(' ', @forward)."\"";
		next;
	}

# Is it a pipe?
	if (/^\|/)
	{
		$valid = 0;

# We can only handle vacation.
		if ((/vacation/) && ( -e "$homedir/.vacation.msg" ))
		{
			@vacargs = split;

# Pare down the line until all we have are the arguments passed to vacation.
			while(!(($i = shift(@vacargs)) =~ /vacation/)){}

# Parse the arguments.
			while ($i = shift(@vacargs))
			{
				if ($i =~ /-a/)
				{
					$i = shift(@vacargs);
					$i =~ s/\"//g;
				}

				$vacaddrs[scalar(@vacaddrs)] = "\"$i\@$domain\"";
			}

# If .vacation.msg doesn't exist then what's the point?
			next if (! open(VACMSG, "<$homedir/.vacation.msg"));

			$vacsubj = '';

# Parse the message, extracting the "Subject:" header as Sieve's vacation uses an
# argument for this part.
			while($msgline = <VACMSG>)
			{
				if ($msgline =~ /^[a-zA-Z-]+:/)
				{
					if ($msgline =~ /^Subject/)
					{
						($junk, $vacsubj) = split(': ', $msgline);
					}
					chomp($vacsubj);
				}
				else
				{
					$vacmess = join('', $vacmess, $msgline);
				}
			}

			close(VACMSG);

# Sieve's vacation is a strange beast, we have to generate it as a match rather than an action.
			$matches[scalar(@matches)] = join(' ', 'vacation', ':days 10', ':addresses', '['.join(',', @vacaddrs).']', ((length($vacsubj) > 0) ? ":subject \"$vacsubj\"" : ''), "\"$vacmess\";");

			$filed = 0 if ($copy == 0);
			$valid++;
		}
		next;
	}

# Now we parse destination folder addresses..

# Strip out any folder prefixes.
	s?Mail/??;

# A special case for /dev/null as this becomes a discard line, otherwise save to a file.
	if (/\/dev\/null/)
	{
		$actions[scalar(@actions)] = "discard";
	}
	else
	{
		$actions[scalar(@actions)] = 'fileinto "'.$_.'"';
	}
}

# By the time we get here we've got a dangling recipe which we need to flush...

if ($valid > 0)
{
	print join("\n", @matches), "\n" if ($#matches >= 0);

	if (scalar(@actions) >= 0)
	{
		print "\t", join(";\n\t", @actions), ";\n" if ($#actions >= 0);

		print "\tdiscard;\n" if (($copy == 0) && ($filed == 0));
		print "}\n\n";
	}
}
