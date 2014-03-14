#!/usr/bin/perl
=description

Authors:
Alexander Kaidalov <kaidalov@fastvps.ru>
Pavel Odintsov <odintsov@fastvps.ee>
License: GPLv2

=cut

# TODO
# Добавить выгрузку информации по Физическим Дискам: 
# megacli -PDList -Aall
# arcconf getconfig 1 pd
# Перенести исключение ploop на этап идентификации дисковых устройств
# Добавить явно User Agent как у мониторинга, чтобы в случае чего их не лочило
# В случае Adaptec номер контроллера зафикисрован как 1

use strict;
use warnings;

use LWP::UserAgent;
use HTTP::Request::Common qw(GET POST);
use File::Spec;

use Data::Dumper;

# Конфигурация
my $VERSION = "1.0";

# diagnostic utilities
my $ADAPTEC_UTILITY = '/usr/local/bin/arcconf';
my $LSI_UTILITY = '/opt/MegaRAID/MegaCli/MegaCli64';

# API
my $API_URL = 'https://bill2fast.com/monitoring_control.php';

# Centos && Debian uses same path
my $parted = "LANG=POSIX /sbin/parted";

# Обанаруживаем все устройства хранения
my @disks = find_disks();

# Проверим, все ли у нас тулзы для диагностики установлены
check_disk_utilities(@disks);

my $only_detect_drives = 0;

# Запуск из крона
my $cron_run = 0;

if (scalar @ARGV > 0 and $ARGV[0] eq '--detect') {
    $only_detect_drives = 1;
}

if (scalar @ARGV > 0 and $ARGV[0] eq '--cron') {
    $cron_run = 1;
}

if ($only_detect_drives) {
    for my $storage (@disks) {
        print "Device $storage->{device_name} with type: $storage->{type} model: $storage->{model} detected\n";
    }

    exit (0);
}

# get all info from disks
@disks = diag_disks(@disks);

if ($cron_run) {
    if(!send_disks_results(@disks)) {
        print "Failed to send storage monitoring data to FastVPS";
        exit(1);
    }   
}

if (!$only_detect_drives && !$cron_run) {
    print "This information was gathered and will be sent to FastVPS:\n";
    print "Disks found: " . (scalar @disks) . "\n\n";

    for my $storage (@disks) {
        print $storage->{device_name} . " is " . $storage->{'type'} . " Diagnostic data:\n";
        print $storage->{'diag'} . "\n\n";
    }       
}



#
# Functions
#

# Функция обнаружения всех дисковых устройств в системе
sub find_disks {
    # here we'll save disk => ( info, ... )
    my @disks = ();
    
    # get list of disk devices with parted 
    my @parted_output = `$parted -lms`;

    if ($? != 0) {
        die "Can't get parted output. Not installed?!";
    }
 
    for my $line (@parted_output) {
        chomp $line;
        # skip empty line
        next if $line =~ /^\s/;
        next unless $line =~ m#^/dev#;   

        # После очистки нам приходят лишь строки вида:
        # /dev/sda:3597GB:scsi:512:512:gpt:DELL PERC H710P;
        # /dev/sda:599GB:scsi:512:512:msdos:Adaptec Device 0;
        # /dev/md0:4302MB:md:512:512:loop:Linux Software RAID Array;
        # /dev/sdc:1500GB:scsi:512:512:msdos:ATA ST31500341AS;

        # Отрезаем точку с запятой в конце
        $line =~ s/;$//; 
            
        # get fields
        my @fields = split ':', $line;
        my $device_name = $fields[0];        
        my $device_size = $fields[1]; 
        my $model = $fields[6];

        # Это виртуальные устройства в OpenVZ, их не нужно анализировать
        if ($device_name =~ m#/dev/ploop\d+#) {
            next;
        }

        # detect type (raid or disk)
        my $type = 'disk';
        my $is_raid = '';                 
   
        # adaptec
        if($model =~ m/adaptec/i) {
            $model = 'adaptec';
            $is_raid = 1;
        }
            
        # Linux MD raid (Soft RAID)
        if ($device_name =~ m/\/md\d+/) {
            $type = 'md';
            $is_raid = 1;
        }

        # LSI (3ware) / DELL PERC (LSI chips also)
        if ($model =~ m/lsi/i or $model =~ m/PERC/i) {
            $type = 'lsi';
            $is_raid = 1;
        }
        
        # add to list
        my $tmp_disk = { 
            "device_name" => $device_name,
            "size"        => $device_size,
            "model"       => $model,
            "type"        => ($is_raid ? 'raid' : 'hard_disk'),
        };  

        push @disks, $tmp_disk;
    }

    return @disks;
}

# Check diagnostic utilities availability
sub check_disk_utilities {
    my (@disks) = @_;

    my $adaptec_needed = 0;
    my $lsi_needed = 0;

    for my $storage (@disks) {
        # Adaptec
        if ($storage->{model} eq "adaptec") {
            $adaptec_needed = 1;
        }
            
        # LSI
        if ($storage->{model} eq "lsi") {
            $lsi_needed = 1;
        }
    }

    if ($adaptec_needed) {
        die "Adaptec utility not found. Please, install Adaptech raid management utility into " . $ADAPTEC_UTILITY . "\n" unless -e $ADAPTEC_UTILITY;
    }

    if ($lsi_needed) {
        die "not found. Please, install LSI MegaCli raid management utility into " . $LSI_UTILITY . " (symlink if needed)\n" unless -e $LSI_UTILITY
    }
}

# Run disgnostic utility for each disk
sub diag_disks {
    my (@disks) = @_;

    foreach my $storage (@disks) {
        my $device_name = $storage->{device_name};
        my $type = $storage->{type};
        my $model = $storage->{model};

        my $res = '';
        my $cmd = '';
        
        if ($type eq 'raid') {
            # adaptec
            if ($model eq "adaptec") {
                $cmd = $ADAPTEC_UTILITY . " getconfig 1 ld";
            }   

            # md
            if ($type eq "md") {    
                $cmd = 'cat /proc/mdstat';
            }

            # lsi (3ware)
            if($type eq "lsi") {
                # it may be run with -L<num> for specific logical drive
                $cmd = $LSI_UTILITY . " -LDInfo -Lall -Aall";
            }
        } elsif ($type eq 'hard_disk') {
            $cmd = "smartctl --all $device_name";
        } else {
            warn "Unexpected type";
            $cmd = '';
        }

        if ($cmd) {
            $res = `$cmd 2>&1`;
        }

        $storage->{"diag"} = $res;
    }

    return @disks;
}

# Send disks diag results
sub send_disks_results {
    my (@disks) = @_;

    for my $storage (@disks) {
        # send results
        my $status = 'error';
        $status = 'success' if $storage->{diag} ne '';
                
        my $req = POST($API_URL, [
            action        => "save_data",
            status        => $status,
            agent_name    => 'disks',
            agent_data    => $storage->{diag},
            agent_version => $VERSION,
            disk_name     => 'disk name',
            disk_type     => 'raid',
            disk_model    => 'adaptec',
            diag          => $storage->{diag},
        ]);

        # get result
        my $ua = LWP::UserAgent->new();
        my $res = $ua->request($req);
                
        # TODO: check $res? old data in monitoring system will be notices
        #       one way or the other...

        return $res->is_success;
    }
}

