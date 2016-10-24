#/usr/local/bin/perl
# Discogs tagging helper, mostly conceived for vinyl releases.
# The input must be album directories named with  a discogs release name or with the format "Artist - Album"

use strict;
use warnings;

use utf8;
use Encode;
binmode(STDOUT, ":utf8");
use open qw(:std :utf8);

use Getopt::Std;                            # Handle options
use LWP::UserAgent;                         # I want to use teh interwebs
use URI::Escape;                            # uri_escape()
use JSON::XS;                               # decode_json()
use File::Copy;                             # copy()
use Audio::FLAC::Header;                    # deal with tagging on &tag_files
use Term::ANSIColor qw(:constants colored); # Colors. Everywhere.
$Term::ANSIColor::AUTORESET = 1;

$> = $) = 2222; print "Effective UID(GID) = $>($))\n"; # Change and uncomment if needed

our $opt_p = undef;  # Preffix to handle stuff like the ripper of vinyl sources.
our $opt_f = qr/.*/; # Narrow results on our queries, 'Vinyl|LP|\d+"' for example.;
our $opt_r = undef;  # Force our release id
getopts('p:f:r:') or die RED BOLD "Usage: $0 [-p [PREFFIX] -f [FORMAT] -r [DISCOGS_RELEASE_ID] <directories>";
$opt_p = decode('UTF-8', $opt_p); # Dat russian vinyl rippers...

my $key            = 'rAzVUQYRaoFjeBjyWuWZ';             # Taken From the beets discogs plugin...
my $secret         = 'plxtUTqoCzwxZpqdPysCwGuBSmZNdZVy'; #
my $ua             = LWP::UserAgent->new( timeout       => 10
                                        , keep_alive    => 10
                                        , show_progress => 1
                                        , ssl_opts      => { verify_hostname => 1 }
                                        );

print YELLOW "- Using preffix option: $opt_p\n" if defined $opt_p;
print YELLOW "- Using format option: $opt_f\n" if defined $opt_f;
print YELLOW "- Using release option: $opt_r\n" if defined $opt_r;

# {{{ sub clean_string
sub clean_string {
    my $string = shift;
    $string =~ s/(?<!^)[\[\{\(].*?[\)\}\]]//g; # remove comments
#    $string =~ s/,.*$//g;                      # only keep first result of a flattened array
    $string =~ s/^\s+|\s+$//g;                 # Remove spaces at beginning/end of string
    return $string;
}
# }}}
# {{{ sub escapename
sub escapename { # Thanks @ File-Util/File/Util.pm
    my $file = shift or return '';
    my $ILLEGAL_CHR = qr/[\x5C\/\|\r\n\t\013\*\"\?\<\:\>]/;
    $file =~ s/$ILLEGAL_CHR/\-/g;
    return $file;
}
# }}}
# {{{  sub discogs_request
sub discogs_request {
    my $uri = shift;
    my @headers = ( 'User-Agent'      => 'WWW-Discogs/0.14 +perl'
                  , 'Accept-Encoding' => 'gzip, deflate'
                  , 'Authorization'   => "Discogs key=$key, secret=$secret"
                  );
    my $resp = $ua->get($uri, @headers);
    unless ($resp->is_success) {
        print RED "- Failed to fetch '$uri'\n";
        print RED $resp->status_line."\n";
        print RED $resp->headers_as_string."\n";
        exit 1;
        return 0;
    }
    return JSON::XS::decode_json($resp->decoded_content);
}
 # }}}
# {{{ sub query_discogs
sub query_discogs {
    my ($type, $one, $two) = map { uri_escape_utf8($_) } @_; # We need spaces as '+'
    $two = "" unless $two;
    my $auth = "per_page=100";
    my %types = ( release  => "/releases/$one?$auth"
                , master   => "/masters/$one?$auth"
                , versions => "/masters/$one/versions?$auth"
                , search   => "/database/search?q=$one+-+$two&type=master&release_title=$two&$auth"
                );
    return unless $types{$type};
    print "- Fetching $type: $one $two\n";
    my $result = discogs_request("https://api.discogs.com$types{$type}") or return;
    $result->{released} =~ s/\D.+//g if $result->{released}; # Clean the year format
    return $result;
}
# }}}
# {{{ sub find_version
sub get_versions {
    my ($artist, $album) = @_;
    print YELLOW "# Searching masters for artist '$artist' and album '$album'\n";
    my $results_ref = ();
    my $masters_hashref = query_discogs('search', $artist, $album);

    foreach my $master ( @{ $masters_hashref->{results} } ) {
        next unless $master->{year} and $master->{label} and $master->{catno} and $master->{country} and $master->{format};

        my $master_release = query_discogs('master', $master->{id});
        @{$master}{keys %$master_release} = values %$master_release;
        $results_ref->{$master->{id}} = $master;

        my $versions_hashref = query_discogs('versions', $master->{id});
        foreach my $version ( @{ $versions_hashref->{versions} } ) {
            next unless $version->{released} and $version->{label} and $version->{catno} and $version->{country} and $version->{format};
            next unless $version->{format} =~ /$opt_f/i; # Only keep the results of our desired media formats
            $version->{released} =~ s/\D.+//g; # Only year
            $results_ref->{$master->{id}}->{versions}->{$version->{id}} = $version;
        }
    }
    return $results_ref;
}
# }}}
# {{{ sub print_results
sub print_results {
my $results_ref = shift;
foreach my $master ( sort { $results_ref->{$a}->{year} cmp $results_ref->{$b}->{year} } keys %{ $results_ref } ) { # Sort by year
    $master = $results_ref->{$master};
    next unless $master->{versions}; # It can happen
    # Print the Master
    print WHITE BOLD sprintf( "MASTER (%s) %s (%s / %s / %s / %s) [%s] %s, %s\n"
                            , $master->{id}
                            , $master->{title}
                            , $master->{year}
                            , @{ $master->{label} }[0]
                            , $master->{catno}
                            , $master->{country}
                            , join(', ', @{ $master->{format} })
                            , @{ $master->{genres} }[0]
                            , @{ $master->{styles} }[0]
                            );
    # Print each version holding from the master
    foreach my $version ( sort {  $master->{versions}->{$a}->{released} <=> $master->{versions}->{$b}->{released } # Sort by release date...
                               or $master->{versions}->{$a}->{country} cmp $master->{versions}->{$b}->{country}    # then by country
                               or $master->{versions}->{$a}->{id} <=> $master->{versions}->{$b}->{id}              # and finally by release id.
                               }  keys %{ $master->{versions} }
                        ) {
        $version = $master->{versions}->{$version};
        my $id_color = 'green'; $id_color = 'bright_white' if $version->{id} == $master->{main_release}; # Different colot for the version that's actually THE master.
        my $rel_color = 'white'; $rel_color = 'cyan' if $version->{released} == $master->{year};         # Different color for versions with the master's release year.
        printf( "\t(%s) %s (%s / %s / %s / %s) [%s]\n"
              , colored($version->{id}, $id_color)
              , $version->{title}
              , colored($version->{released}, $rel_color)
              , colored($version->{label}, 'blue')
              , colored($version->{catno}, 'magenta')
              , colored($version->{country}, 'yellow')
              , $version->{format}
              );
    }
}
}
# }}}
# {{{ sub choose_version
sub choose_version {
    my $results = shift;
    return unless $results;
    my ($master, $input) = (undef, undef);
    while (1) { # Loop asking for user correct input.
        print "\nEnter the discogs ID or just <enter> to skip: ";
        $input = <STDIN>;
        chomp($input);
        last unless $input; # Got no input
        ($master) = grep { defined $results->{$_}->{versions}->{$input} } keys %{ $results }; # Look if we got a matching master for the version/release id
        return ($master, $input) if $master; # User's input matched a master
    }
}
# }}}
# {{{ sub choose_media
sub choose_media {
    my $release = shift;
    print YELLOW "# Release got different media, we must choose one:\n";
    foreach my $track ( @{ $release->{tracklist} } ) {
        print CYAN "'$track->{title}'\n" if $track->{type_} eq 'heading';
        print MAGENTA "\t$track->{position} - $track->{title} $track->{duration}\n" if  $track->{type_} eq 'track';
    }
    print "\nEnter a string to distinguish this media ('CD1', for example) or just <enter> to skip : ";
    my $input = <STDIN>;
    chomp($input);
    return $input;
}
# }}}
# {{{ sub build_album_name
sub build_album_name {
    my ($master_year, $release) = @_;
    my @album_info = ( clean_string($release->{labels}->[0]->{name}), clean_string($release->{labels}->[0]->{catno}) );
    unshift(@album_info, $release->{released}) if $release->{released} > $master_year;
    push(@album_info, $release->{media_name}) if $release->{media_name};
    push(@album_info, $release->{country} || 'Unknown');
    push(@album_info, $opt_p) if defined $opt_p;
    $release->{title} =~ s/^\s+|\s+$//g;
    return "$release->{title} (".join(' / ', @album_info).")";
}
# }}}
# {{{sub copy_files
sub copy_files {
    my ($dir, $album_name) = @_;
    opendir(DIR, $dir) || die RED BOLD "# Can't opendir $dir: $!\n";
    my @files = grep { !/^\.+$/ && /^.*flac$/i } map { decode('utf8', $_); } sort readdir(DIR);
    closedir DIR;
    my $newdir = $album_name;
    print YELLOW "# Creating directory '$newdir' under '$ENV{PWD}'\n";
    mkdir($newdir) or die RED BOLD "# Error '$!' trying to mkdir '$newdir'.";
    foreach my $file (@files) {
        my $file_with_path = "$dir/$file";
        my $size = -s $file_with_path;
        print "- Copying '$file' ($size bytes): ";
        my $result = copy($file_with_path, $newdir) or die RED BOLD "# Error '$!' trying to copy '$file_with_path' into '$newdir'.";
        $result ? print GREEN "OK\n" : print RED "Error!\n";
    }
}
# }}}
# {{{sub tag_files
sub tag_files {
    my ($dst_dir, $album_name, $master, $release) = @_;
    opendir(DIR, $dst_dir) || die RED BOLD "# Can't opendir '$dst_dir': $!\n";
    my @files = grep { !/^\.+$/ && /^.*flac$/i } map { decode('utf8', $_); } sort readdir(DIR);
    closedir DIR;
    print YELLOW "# Tagging\n";
    foreach my $file (@files) {
        print "- Tagging '$file': ";
        my $flac = Audio::FLAC::Header->new("$dst_dir/$file");
        $flac->{tags}->{ARTIST}              = clean_string($master->{artists}->[0]->{name});
        $flac->{tags}->{ALBUM}               = $album_name;
        $flac->{tags}->{ALBUMNAME}           = $release->{title};
        $flac->{tags}->{DATE}                = $flac->tags->{ORIGINALDATE} = $master->{year};
        $flac->{tags}->{RELEASEDATE}         = $release->{year};
        $flac->{tags}->{GENRE}               = @{ $master->{genres} }[0] || @{ $release->{genres} }[0];
        $flac->{tags}->{STYLE}               = @{ $master->{styles} }[0] || @{ $release->{styles} }[0] || $flac->tags->{GENRE};
        $flac->{tags}->{MEDIA}               = $release->{formats}->[0]->{name};
        $flac->{tags}->{MEDIA_NAME}          = $release->{media_name} if $release->{media_name};
        $flac->{tags}->{MEDIA_NUM}           = $release->{format_quantity} if $release->{format_quantity};
        $flac->{tags}->{LABEL}               = $release->{labels}->[0]->{name};
        $flac->{tags}->{CATALOGNUMBER}       = $release->{labels}->[0]->{catno};
        $flac->{tags}->{RELEASECOUNTRY}      = $release->{country} || 'Unknown';
        $flac->{tags}->{BITSPERSAMPLE}       = $flac->{info}->{BITSPERSAMPLE};
        $flac->{tags}->{SAMPLERATE}          = $flac->{info}->{SAMPLERATE};
        $flac->{tags}->{EXTRA}               = $opt_p if $opt_p;
        $flac->{tags}->{DISCOGS_RELEASE_ID}  = $release->{id};
        $flac->{tags}->{DISCOGS_RELEASE_URL} = "http://www.discogs.com/release/$release->{id}";
        $flac->{tags}->{DISCOGS_MASTER_ID}   = $master->{id};
        $flac->{tags}->{DISCOGS_MASTER_URL}  = "http://www.discogs.com/master/view/$master->{id}";

        #Tag Cleaning, mainly avoid non uppercase duplicates
        foreach my $tag ( keys %{ $flac->{tags} } ) {
            if ($tag =~ /[a-z]/) {
                if ($flac->tags->{uc($tag)}) {
                    print RED "- Deleting TAG '$tag' => '$flac->{tags}->{$tag}', we already have '".uc($tag)."' => '$flac->{tags}->{uc($tag)}'.\n";
                    delete $flac->tags->{$tag};
                }
            }
        }

        $flac->write() ? print GREEN "OK\n" : print RED "Failed!\n"
    }
}
# }}}
# {{{ sub fetch_cover
sub fetch_cover {
    my ($dst_dir, $master, $release) = @_;
    print YELLOW "# Fetching cover\n";
    # Use the release and master sources  in that order
    foreach my $source ( $release, $master ) {
         $source->{images}->[0]->{uri} ? print "- Found a cover... " : next;
         my $resp = $ua->get( $source->{images}->[0]->{uri}, ':content_file' => "$dst_dir/folder.jpg" );
         $resp->is_success ? print GREEN "OK\n" : print RED "Error!\n";
         return 0 if $resp->is_success;
    }
    # If we're here we failed miserably.
    print RED "- No cover found!\n";
}
# }}}
# Main loop
foreach my $src_dir (@ARGV) {
    $src_dir = decode("utf-8", $src_dir);
    if (-d $src_dir) {
        my ($dirname) = $src_dir =~ /([^\/]+)(?:|\/)$/;
        print YELLOW BOLD "# Using '$dirname'\n";
        my ($master_id, $master, $release_id, $release) = (undef, {}, undef, {});
        $dirname = $opt_r if defined $opt_r;
        if ($dirname =~ /^\d+$/) { # our dirname seems to be a discogs relase id
            $release_id = $dirname;
            $release = query_discogs('release', $release_id);
            $master_id = $release->{master_id};
            $master = query_discogs('master', $master_id) if $master_id;
        } elsif (my ($artist, $album) = $dirname =~ /(.+?) - (.+)/) { # our dirname seems to names as 'Album - Title'
            $album = clean_string($album);
            my $results = get_versions($artist, $album);
            print_results($results);
            ($master_id, $release_id) = choose_version($results);
            ($master, $release) = ( $results->{$master_id}, query_discogs('release', $release_id) ) if $release_id;
        }
        # Show what we have
        print RED "# Got no master, using release only!.\n" and $master = $release unless $master_id;
        print BOLD RED "# Got no release, skipping!\n" and next unless $release_id;
        $release->{media_name} = choose_media($release) if $release->{format_quantity} > 1;
        # From here eveyrhing is automatic
        my $album_name = build_album_name($master->{year}, $release);
        my $dst_dir = &escapename(clean_string($master->{artists}->[0]->{name})." - $master->{year} - $album_name");
        print YELLOW "# Going with '$dst_dir'\n";
        print "- MASTER URL: 'http://www.discogs.com/master/view/$master_id'\n" if $master_id;
        print "- RELEASE URL: 'http://www.discogs.com/release/$release_id'\n";
        copy_files($src_dir, $dst_dir);
        tag_files($dst_dir, $album_name, $master, $release);
        fetch_cover($dst_dir, $master, $release);
    }
}
