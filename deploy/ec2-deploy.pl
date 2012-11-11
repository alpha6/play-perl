#!/usr/bin/env perl

=head1 NAME

ec2-deploy.pl - deploy play-perl.org code to Amazon EC2

=head1 SYNOPSIS

  ec2-deploy.pl [--create]
    options:
      --create      Create the new instance

=head1 DESCRIPTION

Generally, only C<cpan:MMCLERIC> uses this script for deploying play-perl.org to production. All other contributors should use local vagrant VM instead, as described in README.

=cut


use strict;
use warnings;
use 5.010;

use Getopt::Long 2.33;
use Pod::Usage;

use IPC::System::Simple;
use autodie qw(:all);

use Term::ANSIColor qw(:constants);
$Term::ANSIColor::AUTORESET = 1;

# play-perl.org address, as registered in GoDaddy DNS
my $IP = '54.243.208.16';
my $USER = 'ubuntu';

sub xqx {
    my $command = join ' ', @_;
    my $result = qx($command);
    if ($?) {
        die "Command '$command' failed";
    }
    return $result;
}

sub INFO {
    say GREEN @_;
}

sub wait_for_bootstrap {
    INFO "Waiting for bootstrap to complete";
    STDOUT->autoflush(1);
    for my $trial (1..20) {
        eval {
            system(qq{ssh -q -t $USER\@$IP "sudo -i which chef-solo > /dev/null"})
        };
        if ($@) {
            print '.';
            sleep 5;
            next;
        }
        INFO "chef-solo is ready";
        return;
    }
    print "\n";
    die "Timeout, check /var/log/user-data.log to find out why bootstrap.sh failed";
}

sub provision {
    INFO "Running chef-solo";
    system(qq{ssh -t $USER\@$IP "sudo -i sh -c 'chef-solo -c /tmp/cheftime/solo.rb -j /home/ubuntu/dna.json -r /home/ubuntu/cookbooks.tgz'"});
    INFO "Provisioning complete";
}

sub start_instance {
    INFO "Creating EC2 instance";
    my @command = ('ec2-run-instances',
        'ami-3d4ff254', # ubuntu 12.04
        '--instance-type', 't1.micro',
        '--user-data-file', 'deploy/bootstrap.sh',
        '--key', 'aws', # replace with your key pair name
    );
    my $result = xqx(@command);

    my ($instance) = $result =~ /^INSTANCE \s+ (i-\S+)/mx;
    INFO "Instance $instance created";

    system("ec2-associate-address -i $instance $IP");
    INFO "IP $IP associated with $instance";

    system("ssh-keygen -R $IP") if -e "$ENV{HOME}/.ssh/known_hosts";
    INFO "Old ssh host key removed";

    {
        my $ok;
        for my $trial (1..5) {
            my $key = xqx("ssh-keyscan $IP 2>/dev/null");
            unless ($key) {
                # too early
                sleep 3;
                next;
            }
            open my $fh, '>>', "$ENV{HOME}/.ssh/known_hosts";
            print {$fh} $key;
            close $fh;
            $ok = 1;
            last;
        }
        die "Couldn't obtain ssh host key" unless $ok;
    }
    INFO "New ssh host key obtained";
}

sub main {

    my $create;
    GetOptions(
        'create!' => \$create,
    ) or pod2usage(2);
    pod2usage(2) if @ARGV;

    if ($create) {
        start_instance();
        wait_for_bootstrap();
    }

    system('tar cfz cookbooks.tgz cookbooks');
    system("scp -r cookbooks.tgz dna.json $USER\@$IP:.");

    provision();
}

main unless caller;

=head1 SEE ALSO

This script is based on L<https://github.com/lynaghk/vagrant-ec2>.

=cut