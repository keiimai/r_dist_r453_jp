#!/bin/bash
# =============================================================================
# Diagnose the environment only (Mac). It does not start Docker, download, build or change settings.
# In Terminal type "bash ", drag this file into the window and press Enter ("If something goes wrong" in HOW_TO_USE_Mac.html).
# The same file is used in r_launcher_jp/_en and python_launcher_jp/_en (language from launcher/start_messages.txt).
# =============================================================================
cd "$(dirname "$0")" || exit 1
exec /usr/bin/perl - "$PWD" "$@" <<'LAUNCHER_DIAGNOSTIC_PERL'
use strict;
use warnings;
use utf8;
use JSON::PP;
use Digest::SHA qw(sha256_hex);
use Time::HiRes qw(clock_gettime CLOCK_MONOTONIC sleep);
use POSIX qw(strftime WNOHANG);
use IPC::Open3;
use IO::Select;
use Symbol qw(gensym);
use File::Basename qw(basename);
use File::Path qw(make_path);
use Encode qw(decode FB_DEFAULT);
binmode STDOUT, ':encoding(UTF-8)';
binmode STDERR, ':encoding(UTF-8)';

my $root = shift @ARGV;
my $self = $root.'/diagnose_mac.command';
my $language = 'en';
if (open(my $messages, '<:encoding(UTF-8)', "$root/launcher/start_messages.txt")) {
    while (my $line = <$messages>) { if ($line =~ /^language=(ja|en)\r?$/) { $language = $1; last; } }
    close $messages;
}
my $kind = -f "$root/DESCRIPTION" || -f "$root/renv.lock" ? 'R' : -f "$root/pyproject.toml" ? 'Python' : undef;
my %profile = !defined $kind ? (prefix => 'r', app => 'the analysis environment', lock => undef, manifest => undef, services => []) :
    $kind eq 'R' ? (prefix => 'r', app => 'RStudio', lock => 'renv.lock', manifest => 'DESCRIPTION',
        services => [['docker_registry', 'https://registry-1.docker.io/v2/'], ['posit_package_manager', 'https://packagemanager.posit.co/cran/']]) :
    (prefix => 'py', app => 'JupyterLab', lock => 'uv.lock', manifest => 'pyproject.toml',
        services => [['docker_registry', 'https://registry-1.docker.io/v2/'], ['github_container_registry', 'https://ghcr.io/v2/'], ['python_package_index', 'https://pypi.org/simple/']]);
my @package_names = grep { defined } ('start_mac.command', 'diagnose_mac.command', 'launcher/start_messages.txt', 'Dockerfile', 'docker-compose.yml',
    $profile{manifest}, $profile{lock}, 'TEMPLATE_VERSION.txt');
my $records_dir = $root.'/outputs/launcher';
my $incident_name;
my ($network, $share, $image_override) = (0, 0, undef);
for my $arg (@ARGV) {
    if ($arg eq '--network') { $network = 1; }
    elsif ($arg eq '--share-test') { $share = 1; }
    elsif ($arg =~ /^--image=([A-Za-z0-9][A-Za-z0-9_.:\/\@-]*)$/) { $image_override = $1; }
    elsif ($arg =~ /^--incident=(launch_[A-Za-z0-9_.-]+\.jsonl)$/) { $incident_name = $1; }
    elsif ($arg eq '--help') {
        print "bash diagnose_mac.command [--network] [--share-test] [--image=existing-tag]\n",
            "--incident=launch_<ID>.jsonl: summarize one launch record in outputs/launcher/ only; no live probes.\n",
            "Default: local observations only; no Docker start, downloads, builds or settings changes.\n",
            "--network: HTTPS checks to the image and package sources, without downloading packages.\n",
            "--share-test: synthetic two-way sharing check using an existing local image.\n",
            "Exit: 0 prerequisites met; 2 preparation needed; 3 review needed; 1 record unavailable.\n";
        exit 0;
    } else { print STDERR "Unknown option: $arg (see --help)\n"; exit 1; }
}
my $started = clock_gettime(CLOCK_MONOTONIC);
open my $random, '<:raw', '/dev/urandom' or die "Cannot create diagnostic run identifier.\n";
read $random, my $random_bytes, 16;
close $random;
my $run_id = unpack('H*', $random_bytes);
my $json = JSON::PP->new->canonical->pretty->utf8;
my $tool_version = '1.0.0';
my $rules_version = '2026-11-17';
my $report = {
    schema_version => '1.0', record_kind => 'launcher_environment_check', tool_version => $tool_version, rules_version => $rules_version,
    run_id => $run_id, started_at => strftime('%Y-%m-%dT%H:%M:%SZ', gmtime), platform => 'macOS', environment => $kind,
    probes => [], checks => [],
    scope => { analysis => 'not_run', vendor_support_lifecycle => 'not_evaluated',
        configuration_changes => JSON::PP::false, network_requested => $network ? JSON::PP::true : JSON::PP::false,
        share_test_requested => $share ? JSON::PP::true : JSON::PP::false },
    criteria => { host_memory_minimum_bytes => 4_000_000_000,
        memory_rule_scope => 'Docker prerequisite, not an analysis memory guarantee',
        references => ['https://docs.docker.com/desktop/setup/install/mac-install/'] }
};

sub clean {
    my $value = defined $_[0] ? "$_[0]" : '';
    $value = decode('UTF-8', $value, FB_DEFAULT) unless utf8::is_utf8($value);
    for my $prefix (sort { length($b) <=> length($a) } grep { defined && length } ($root, $ENV{HOME})) {
        my $decoded_prefix = utf8::is_utf8($prefix) ? $prefix : decode('UTF-8', $prefix, FB_DEFAULT);
        $value =~ s/\Q$decoded_prefix\E/<LOCAL_PATH>/g;
    }
    $value =~ s{(https?://)[^\s/\@]+\@}{$1<REDACTED>\@}gi;
    $value =~ s{((?:proxy-)?authorization\s*[=:]\s*)[^\r\n]*}{$1<REDACTED>}gi;
    $value =~ s{((?:password|token|secret|authorization)\s*[=:]\s*)[^\s,;]+}{$1<REDACTED>}gi;
    return substr($value, 0, 1600);
}
sub read_text {
    my ($path) = @_;
    return undef unless -f $path && -r $path;
    open my $file, '<:raw', $path or return undef;
    local $/; my $value = <$file>; close $file;
    return $value;
}
sub digest { my $bytes = read_text($_[0]); return defined $bytes ? sha256_hex($bytes) : undef; }
sub check { my ($id, $status, $reason) = @_; push @{$report->{checks}}, {id => $id, status => $status, reason => $reason}; }
sub execute {
    my ($id, $seconds, @command) = @_;
    my $begin = clock_gettime(CLOCK_MONOTONIC);
    my ($status, $exit_code, $stdout, $stderr, $cleanup_pending) = ('unavailable', undef, '', '', undef);
    my ($input, $output, $error, $pid);
    eval {
        $error = gensym; $pid = open3($input, $output, $error, @command); close $input;
        my $selector = IO::Select->new($output, $error);
        my $output_fd = fileno($output);
        my ($reaped, $wait_status) = (0, 0);
        while ($selector->count || !$reaped) {
            if (clock_gettime(CLOCK_MONOTONIC) - $begin >= $seconds) {
                $status = 'timed_out';
                unless ($reaped) {
                    kill 'TERM', $pid; sleep 0.15;
                    if (waitpid($pid, WNOHANG) == $pid) { $reaped = 1; }
                    else {
                        kill 'KILL', $pid;
                        my $cleanup_deadline = clock_gettime(CLOCK_MONOTONIC) + 1;
                        while (clock_gettime(CLOCK_MONOTONIC) < $cleanup_deadline) {
                            if (waitpid($pid, WNOHANG) == $pid) { $reaped = 1; last; }
                            sleep 0.05;
                        }
                        $cleanup_pending = $pid unless $reaped;
                    }
                }
                last;
            }
            for my $handle ($selector->can_read(0.05)) {
                my $count = sysread($handle, my $buffer, 8192);
                if (defined $count && $count > 0) {
                    if (fileno($handle) == $output_fd) { $stdout .= $buffer if length($stdout) < 65536; }
                    else { $stderr .= $buffer if length($stderr) < 65536; }
                } else { $selector->remove($handle); close $handle; }
            }
            if (!$reaped && waitpid($pid, WNOHANG) == $pid) { $reaped = 1; $wait_status = $?; }
            if ($reaped && !$selector->count) {
                $exit_code = ($wait_status & 127) ? 128 + ($wait_status & 127) : $wait_status >> 8;
                $status = $exit_code == 0 ? 'ok' : 'failed';
            }
        }
        for my $handle ($selector->handles) { close $handle; }
    };
    $stderr .= $@ if $@; $stderr = clean($stderr);
    $status = 'permission_denied' if $status eq 'failed' && $stderr =~ /permission denied|operation not permitted|access is denied/i;
    my $entry = {id => $id, status => $status, exit_code => $exit_code,
        elapsed_seconds => 0 + sprintf('%.3f', clock_gettime(CLOCK_MONOTONIC) - $begin), error => $stderr};
    if (defined $cleanup_pending) {
        $entry->{pending_child_pid} = $cleanup_pending;
        check('diagnostic_cleanup', 'unknown', 'A timed-out child has not exited; no other process was terminated.');
    }
    push @{$report->{probes}}, $entry;
    return {status => $status, exit_code => $exit_code, stdout => $stdout, stderr => $stderr};
}
sub text {
    my $r = execute(@_); return undef unless $r->{status} eq 'ok';
    my $value = decode('UTF-8', $r->{stdout}, FB_DEFAULT);
    $value =~ s/^\s+|\s+$//g; return $value;
}
sub sysctl { return text('host_'.$_[0], 5, '/usr/sbin/sysctl', '-n', $_[0]); }
sub number { return defined $_[0] && $_[0] =~ /^\d+(?:\.\d+)?$/ ? 0 + $_[0] : undef; }
sub probe_json { my $r = execute(@_); $r->{value} = eval { JSON::PP->new->utf8->decode($r->{stdout}) }; return $r; }
sub storage {
    my ($path, $id) = @_;
    my $r = {location_hint => $path =~ /CloudStorage|Dropbox|OneDrive|iCloud/i ? 'cloud_sync_possible' :
        $path =~ m{^/Volumes/} ? 'mounted_volume' : 'local', filesystem => undef, free_bytes => undef};
    my $df = text($id.'_disk_free', 8, '/bin/df', '-Pk', $path);
    if (defined $df) {
        my @lines = split /\n/, $df; my @columns = split /\s+/, $lines[-1];
        if (@columns >= 6) {
            $r->{free_bytes} = 0 + $columns[3] * 1024;
            my $point = join ' ', @columns[5..$#columns];
            my $mounts = text($id.'_mount_type', 5, '/sbin/mount');
            if (defined $mounts) { for my $line (split /\n/, $mounts) {
                if ($line =~ /^.+ on \Q$point\E \(([^,\)]+)/) { $r->{filesystem} = $1; last; }
            } }
        }
    }
    return $r;
}
sub hash_files {
    my ($budget) = @_;
    my $hash_started = clock_gettime(CLOCK_MONOTONIC);
    my @files;
    for my $name (@package_names) {
        my $path = $root.'/'.$name;
        my $entry = {path => $name, status => 'not_present'};
        if (defined $budget && clock_gettime(CLOCK_MONOTONIC) - $hash_started > $budget) { $entry->{status} = 'budget_exhausted'; }
        elsif (-l $path) { $entry->{status} = 'symlink_skipped'; }
        elsif (-f $path) {
            if (-s $path > 1048576) { $entry->{status} = 'over_size_limit'; }
            else { $entry->{sha256} = digest($path); $entry->{status} = defined $entry->{sha256} ? 'hashed' : 'unavailable'; }
        }
        push @files, $entry;
    }
    return \@files;
}

# --- Launch records (outputs/launcher/launch_<ID>.jsonl, written by start_mac.command / start_windows.bat) ---
my %failure_stages = map { $_ => 1 } qw(docker_missing docker_timeout ui_timeout);
sub is_failure {
    my ($row) = @_;
    my ($stage, $code) = ($row->{stage} // '', $row->{rc});
    return 1 if $failure_stages{$stage};
    return 0 unless defined $code && $code =~ /^-?\d{1,10}$/ && $code != 0;
    return $stage =~ /_end$/ && $stage ne 'launch_end' && $stage ne 'down_end' ? 1 : 0;
}
sub routine_result {
    my ($item) = @_;
    my (%success, @failures, $last_exit, $last_stop);
    my ($ready_at, $index) = (-1, 0);
    for my $row (@{$item->{events} // []}) {
        my ($stage, $code) = ($row->{stage} // '', $row->{rc});
        my $has_code = defined $code && $code =~ /^-?\d{1,10}$/;
        $last_exit = $row if $stage eq 'launch_end' && $has_code;
        $last_stop = $row if $stage eq 'down_end' && $has_code;
        if ($has_code && $code == 0) {
            $success{$stage} = $index;
            $ready_at = $index if $stage eq 'ui_ready';
        }
        push @failures, [$stage, $index] if is_failure($row);
        $index++;
    }
    my ($recovered, $unresolved) = (0, 0);
    for my $failure (@failures) {
        my ($stage, $at) = @$failure;
        if ((exists $success{$stage} && $success{$stage} > $at) || $ready_at > $at) { $recovered++; }
        else { $unresolved++; }
    }
    my $status = $item->{status} ne 'observed' ? 'record_incomplete' :
        $last_stop && $last_stop->{rc} != 0 ? 'stop_failed' :
        $last_exit && $last_exit->{rc} != 0 ? 'launcher_failed' :
        $unresolved ? 'command_failed' : !$last_exit ? 'exit_not_observed' : $recovered ? 'recovered' : 'completed';
    return {status => $status, launcher_exit_observed => $last_exit ? JSON::PP::true : JSON::PP::false,
        launcher_exit_code => $last_exit ? $last_exit->{rc} : undef, ui_ready_observed => $ready_at >= 0 ? JSON::PP::true : JSON::PP::false,
        stop_exit_code => $last_stop ? $last_stop->{rc} : undef, recovered_failure_count => $recovered, unresolved_failure_count => $unresolved,
        analysis => 'not_evaluated'};
}
sub print_routine_result {
    my ($item) = @_;
    my %messages = $language eq 'ja' ? (
        completed => '起動ファイルの正常終了を記録しました。',
        recovered => '途中の失敗から回復し、起動ファイルの正常終了を記録しました。',
        stop_failed => 'コンテナを止める処理が失敗しました。Docker Desktop の画面で、コンテナが止まったかを確かめてください。',
        launcher_failed => '起動ファイルが失敗して終了しました。',
        command_failed => 'コマンドの失敗を記録しています。その後の回復は未確認です。',
        exit_not_observed => '起動ファイルの終了の記録がありません。実行中か中断かは判定できません。',
        record_incomplete => '記録が不完全なため、終了状態を確定できません。'
    ) : (
        completed => 'Launcher completed successfully.',
        recovered => 'Recovered from an earlier command failure; launcher completed successfully.',
        stop_failed => 'Stopping the container failed. Check in Docker Desktop whether the container has stopped.',
        launcher_failed => 'Launcher exited with a failure.',
        command_failed => 'A command failed; subsequent recovery was not observed.',
        exit_not_observed => 'No launcher exit recorded; it may still be running or may have been interrupted.',
        record_incomplete => 'Incomplete record; completion cannot be established.'
    );
    my $result = $item->{result} // {};
    my $status = $result->{status} // 'record_incomplete';
    print $item->{path}.': '.$messages{$status}."\n";
    if (($result->{recovered_failure_count} // 0) > 0 && $status ne 'recovered') {
        print $language eq 'ja' ? "途中のコマンドの失敗からの回復も記録されています。\n" : "Recovery from an earlier command failure was also observed.\n";
    }
}
sub routine_records {
    my ($only) = @_;
    my @files;
    if (defined $only) { @files = ($records_dir.'/'.$only); }
    elsif (opendir my $directory, $records_dir) {
        @files = map { $records_dir.'/'.$_ } grep { /^launch_[A-Za-z0-9_.-]+\.jsonl$/ } readdir $directory;
        closedir $directory;
    }
    @files = sort { (stat($b))[9] <=> (stat($a))[9] } grep { -f && !-l } @files;
    splice @files, 3 if @files > 3;
    my @items;
    for my $path (@files) {
        my $item = {path => 'outputs/launcher/'.basename($path), bytes => 0 + (-s $path)};
        if ($item->{bytes} > 65536) { $item->{status} = 'over_size_limit'; push @items, $item; next; }
        open my $input, '<:raw', $path or do { $item->{status} = 'unavailable'; push @items, $item; next; };
        my $count = read $input, my $bytes, 65537; close $input;
        if (!defined $count) { $item->{status} = 'unavailable'; push @items, $item; next; }
        $item->{bytes} = $count;
        if ($count > 65536) { $item->{status} = 'over_size_limit'; push @items, $item; next; }
        $item->{sha256} = sha256_hex($bytes);
        my @rows; my $invalid = 0;
        for my $line (split /\r?\n/, $bytes) {
            next unless length $line;
            my $row = eval { JSON::PP->new->utf8->decode($line) };
            if (ref $row ne 'HASH') { $invalid = 1; next; }
            my %selected;
            for my $key (qw(v id t sec clock stage rc)) {
                next unless exists $row->{$key};
                my $v = $row->{$key};
                $selected{$key} = $v if !defined $v || (!ref $v && $v =~ /^[A-Za-z0-9_.,:\/ -]{0,160}$/);
            }
            push @rows, \%selected;
        }
        my $valid = @rows && ($rows[0]{stage} // '') eq 'launch_start';
        $item->{status} = !$valid ? 'invalid_header' : $invalid ? 'partial_record' : 'observed';
        $item->{launcher_completion} = (scalar grep { ($_->{stage} // '') eq 'launch_end' } @rows) ? 'observed' : 'not_observed';
        $item->{events} = \@rows;
        $item->{result} = routine_result($item);
        push @items, $item;
    }
    return {maximum_files => 3, maximum_bytes_per_file => 65536, entries => \@items,
        note => 'Launcher and command results only; container exit and analysis completion are not inferred.'};
}

# --- --incident: summarize one launch record and the package files, with no live probes ---
if (defined $incident_name) {
    my $saved = eval {
        my $source = routine_records($incident_name)->{entries}[0];
        die "Launch record unavailable or invalid.\n" unless $source && $source->{status} =~ /^(observed|partial_record)$/;
        my @conditions = grep { is_failure($_) } @{$source->{events}};
        die "No failure was recorded in this launch record.\n" unless @conditions;
        my $summary = {schema_version => '1.0', record_kind => 'launcher_incident', tool_version => $tool_version, rules_version => $rules_version,
            captured_at => strftime('%Y-%m-%dT%H:%M:%SZ', gmtime), platform => 'macOS', environment => $kind, conditions => \@conditions, result => $source->{result},
            source_snapshot => {path => $source->{path}, bytes => $source->{bytes}, sha256 => $source->{sha256}, status => $source->{status}},
            files => hash_files(0.5), scope => {analysis => 'not_evaluated', docker_queries => JSON::PP::false, network => JSON::PP::false, raw_logs => JSON::PP::false},
            collection_budget_seconds => 0.5};
        $summary->{collection_elapsed_seconds} = 0 + sprintf('%.3f', clock_gettime(CLOCK_MONOTONIC) - $started);
        my $bytes = $json->encode($summary); die "Incident summary exceeded size limit.\n" if length($bytes) > 65536;
        (my $leaf = $incident_name) =~ s/^launch_/incident_/; $leaf =~ s/\.jsonl$/.json/;
        my $output = $records_dir.'/'.$leaf;
        die "Incident output is a link or directory.\n" if -l $output || -d $output;
        my $temp = $output.'.'.$run_id.'.tmp';
        eval {
            open my $file, '>:raw', $temp or die "Cannot save incident summary.\n";
            print {$file} $bytes or die "Cannot write incident summary.\n";
            close $file or die "Cannot finish incident summary.\n";
            rename $temp, $output or die "Cannot finalize incident summary.\n";
        };
        my $error = $@; unlink $temp if -f $temp; die $error if $error;
        print_routine_result($source);
        print $language eq 'ja' ? '問題があったときの記録を outputs/launcher/'.$leaf." に残しました。問い合わせに添えてください。\n" : 'Incident record: outputs/launcher/'.$leaf." (attach it when you ask for help)\n";
        1;
    };
    print STDERR (($language eq 'ja' ? '問題があったときの記録をまとめられなかった理由: ' : 'Incident record unavailable: ').clean($@)."\n") unless $saved;
    exit($saved ? 0 : 1);
}

# --- Default: observe the host, the folder and Docker (nothing is started or changed) ---
eval {
    $report->{tool_sha256} = digest($self);
    check('project_files', -f $root.'/docker-compose.yml' && -f $root.'/Dockerfile' && defined $kind ? 'pass' : 'fail',
        'This file must be inside the analysis folder (the folder with docker-compose.yml and Dockerfile).');
    $report->{routine_records} = routine_records();
    my $arm = sysctl('hw.optional.arm64');
    my $process_arch = text('process_architecture', 5, '/usr/bin/uname', '-m');
    my $translated = sysctl('sysctl.proc_translated');
    my $cpu_model = sysctl('machdep.cpu.brand_string');
    my $native = defined $arm && $arm eq '1' ? 'arm64' : defined $arm && $arm eq '0' ? 'amd64' :
        defined $process_arch && $process_arch eq 'arm64' ? 'arm64' : defined $cpu_model && $cpu_model =~ /Intel|AMD/i ? 'amd64' : undef;
    $report->{host} = {
        os_version => text('os_version', 5, '/usr/bin/sw_vers', '-productVersion'),
        os_build => text('os_build', 5, '/usr/bin/sw_vers', '-buildVersion'),
        native_architecture => $native, process_architecture => $process_arch,
        translated_process => defined $translated ? $translated eq '1' ? JSON::PP::true : JSON::PP::false : undef,
        cpu_model => $cpu_model, physical_cores => number(sysctl('hw.physicalcpu')),
        logical_cpus => number(sysctl('hw.logicalcpu')), memory_total_bytes => number(sysctl('hw.memsize')),
        load_average => sysctl('vm.loadavg'), swap_usage => sysctl('vm.swapusage')
    };
    check('cpu_architecture', defined $native ? 'pass' : 'unknown', defined $native ? 'Native target is linux/'.$native.'.' : 'Native CPU could not be determined.');
    my $memory = $report->{host}{memory_total_bytes};
    check('host_memory', !defined $memory ? 'unknown' : $memory >= $report->{criteria}{host_memory_minimum_bytes} ? 'pass' : 'fail',
        'Docker prerequisite only; analysis requirements depend on the analysis.');
    my $vm = text('memory_pages', 5, '/usr/bin/vm_stat');
    if (defined $vm && $vm =~ /page size of (\d+) bytes/) {
        my $page_size = $1; my $pages = 0;
        for my $key ('Pages free', 'Pages inactive', 'Pages speculative') { $pages += $1 if $vm =~ /\Q$key\E:\s+(\d+)/; }
        $report->{host}{memory_available_estimate_bytes} = $page_size * $pages;
        $report->{host}{memory_available_method} = 'vm_stat: free + inactive + speculative pages; estimate, not guaranteed allocation';
    }
    my $power = text('power_mode', 5, '/usr/bin/pmset', '-g', 'custom');
    $report->{host}{low_power_mode_reported} = defined $power ? $power =~ /lowpowermode\s+1\b/ ? JSON::PP::true : JSON::PP::false : undef;
    $report->{storage} = storage($root, 'project');
    $report->{storage}{folder_writable} = -w $root ? JSON::PP::true : JSON::PP::false;
    check('project_writable', -w $root ? 'pass' : 'fail', 'The analysis folder must accept new files (outputs/ and the launch records).');
    check('project_location', 'warning', 'The folder is in a synced or mounted location; files may be slow or conflict (HOW_TO_USE_Mac.html "2").') if $report->{storage}{location_hint} ne 'local';
    $report->{package} = {files => hash_files(), template_version => []};
    my $stamp = read_text($root.'/TEMPLATE_VERSION.txt');
    $report->{package}{template_version} = [grep { /^(template|launcher) [A-Za-z0-9_.-]+ [0-9a-f]{40,64}$/ } split /\r?\n/, $stamp] if defined $stamp;
    $report->{package}{git_commit} = undef;
    if (-e $root.'/.git') {
        my @git_candidates = ((map { $_.'/git' } split /:/, $ENV{PATH} // ''), '/opt/homebrew/bin/git');
        my ($git) = grep { -f && -x && ($_ ne '/usr/bin/git' || -f '/Library/Developer/CommandLineTools/usr/bin/git') } @git_candidates;
        if (defined $git) {
            my $commit = text('package_git_commit', 5, $git, '-C', $root, 'rev-parse', 'HEAD');
            $report->{package}{git_commit} = $commit if defined $commit && $commit =~ /^[0-9a-f]{40,64}$/;
        }
    }
    my $sum = text('launcher_name', 5, '/bin/bash', '-c', 'printf %s "$1" | /usr/bin/cksum', 'launcher-diagnostic', $root);
    my $base = lc basename($root); $base =~ s/[^a-z0-9]//g; $base ||= $profile{prefix};
    my $name = defined $sum && $sum =~ /^(\d+)/ ? sprintf('%s-%06d', $base, $1 % 1000000) : undef;
    my $image = $image_override // (defined $name ? $name.':dev' : undef);
    $report->{package}{launcher_target} = defined $native ? 'linux/'.$native : undef;
    $report->{package}{expected_image} = $image;

    my @candidates = ((map { $_.'/docker' } split /:/, $ENV{PATH} // ''), ($ENV{HOME} // '').'/.docker/bin/docker',
        '/usr/local/bin/docker', '/opt/homebrew/bin/docker', '/Applications/Docker.app/Contents/Resources/bin/docker');
    my ($docker) = grep { -f && -x } @candidates;
    $report->{docker} = {cli_found => defined $docker ? JSON::PP::true : JSON::PP::false, initial_engine_state => 'not_checked', image => {status => 'not_checked'}, container => {status => 'not_checked'}};
    $report->{docker}{desktop_version} = undef;
    for my $app ('/Applications/Docker.app', ($ENV{HOME} // '').'/Applications/Docker.app') {
        next unless -f $app.'/Contents/Info.plist';
        $report->{docker}{desktop_version} = text('docker_desktop_version', 5, '/usr/bin/defaults', 'read', $app.'/Contents/Info', 'CFBundleShortVersionString');
        last;
    }
    my $ready = 0;
    if (!defined $docker) { check('docker_cli', 'fail', 'Docker CLI not found. Install Docker Desktop (HOW_TO_USE_Mac.html "1").'); }
    else {
        $report->{docker}{cli_version} = text('docker_cli', 10, $docker, '--version');
        my $endpoint;
        if ($ENV{DOCKER_HOST} && !$ENV{DOCKER_CONTEXT}) { $endpoint = $ENV{DOCKER_HOST}; }
        else {
            my $context = text('docker_context', 10, $docker, 'context', 'show');
            $endpoint = text('docker_endpoint', 10, $docker, 'context', 'inspect', $context, '--format', '{{(index .Endpoints "docker").Host}}') if defined $context;
        }
        my $local = defined $endpoint && $endpoint =~ /^(unix|npipe):\/\//;
        $report->{docker}{endpoint_kind} = defined $endpoint ? (split /:/, $endpoint)[0] : 'unknown';
        $report->{docker}{local_endpoint} = $local ? JSON::PP::true : JSON::PP::false;
        if (!$local) { $report->{docker}{initial_engine_state} = 'not_contacted'; check('docker_endpoint', 'unknown', 'Remote or unresolved Docker endpoint was not contacted.'); }
        else {
            my $format = '{"server_version":{{json .ServerVersion}},"os_type":{{json .OSType}},"architecture":{{json .Architecture}},"logical_cpus":{{.NCPU}},"memory_total_bytes":{{.MemTotal}},"kernel_version":{{json .KernelVersion}},"storage_driver":{{json .Driver}},"running_containers":{{.ContainersRunning}}}';
            my $info = probe_json('docker_engine', 20, $docker, 'info', '--format', $format);
            my $v = $info->{value};
            $ready = $info->{status} eq 'ok' && ref $v eq 'HASH' && $v->{server_version} && $v->{kernel_version} && ($v->{os_type} // '') eq 'linux' &&
                ($v->{architecture} // '') =~ /^(aarch64|arm64|x86_64|amd64)$/ && ($v->{logical_cpus} // 0) > 0 && ($v->{memory_total_bytes} // 0) > 0;
            $report->{docker}{engine} = $v;
            $report->{docker}{initial_engine_state} = $ready ? 'responding' : $info->{status} eq 'timed_out' ? 'timed_out' : 'unavailable_or_invalid';
            check('docker_engine', $ready ? 'pass' : $info->{status} =~ /^(timed_out|permission_denied|unavailable)$/ ? 'unknown' : 'fail',
                $ready ? 'Actual local Linux Engine fields returned.' : 'No valid Linux Engine response. Start Docker Desktop and wait for "Engine running"; this check does not start it.');
            if ($ready) {
                $report->{docker}{compose_version} = text('docker_compose', 10, $docker, 'compose', 'version', '--short');
                check('docker_compose', $report->{docker}{compose_version} ? 'pass' : 'fail', 'Docker Compose must be available to the launcher.');
                if (defined $image) {
                    my $im = probe_json('docker_image', 15, $docker, 'image', 'inspect', $image, '--format', '{"id":{{json .Id}},"os":{{json .Os}},"architecture":{{json .Architecture}},"created":{{json .Created}}}');
                    my $valid_image = $im->{status} eq 'ok' && ref $im->{value} eq 'HASH' && ($im->{value}{id} // '') =~ /^sha256:[0-9a-f]{64}$/ && ($im->{value}{os} // '') eq 'linux' && ($im->{value}{architecture} // '') =~ /^(arm64|amd64)$/;
                    $report->{docker}{image} = {status => $valid_image ? 'present' : $im->{status} eq 'ok' || $im->{status} eq 'timed_out' ? 'unknown' : 'not_built_yet', details => $im->{value}};
                    check('image_architecture', 'warning', 'Image and native CPU differ; emulation may be required.') if ref $im->{value} eq 'HASH' && defined $native && ($im->{value}{architecture} // '') ne $native;
                }
                if (defined $name) {
                    my $ci = probe_json('docker_container', 15, $docker, 'container', 'inspect', $name.'_dev', '--format', '{"state":{{json .State.Status}},"oom_killed":{{.State.OOMKilled}},"image_id":{{json .Image}},"memory_limit_bytes":{{.HostConfig.Memory}},"swap_limit_bytes":{{.HostConfig.MemorySwap}},"nano_cpus":{{.HostConfig.NanoCpus}},"cpu_quota":{{.HostConfig.CpuQuota}},"cpu_period":{{.HostConfig.CpuPeriod}},"cpuset":{{json .HostConfig.CpusetCpus}}}');
                    $report->{docker}{container} = {status => $ci->{status} eq 'ok' && ref $ci->{value} eq 'HASH' ? 'present' : $ci->{status} eq 'timed_out' ? 'unknown' : 'not_running', details => $ci->{value}};
                    check('container_oom', 'warning', 'The container was stopped for lack of memory; raise the memory limit in Docker Desktop.') if ref $ci->{value} eq 'HASH' && $ci->{value}{oom_killed};
                }
            }
        }
    }
    my $settings_text = read_text(($ENV{HOME} // '').'/Library/Group Containers/group.com.docker/settings-store.json');
    my $settings = defined $settings_text ? eval { JSON::PP->new->utf8->decode($settings_text) } : undef;
    $report->{docker}{configured_limits} = {status => 'unavailable'};
    if (ref $settings eq 'HASH') {
        my %selected;
        for my $key ('cpus', 'memoryMiB', 'swapMiB', 'diskSizeMiB', 'virtualMachineManager', 'useVirtualizationFrameworkRosetta', 'useVirtualizationFramework') {
            next unless exists $settings->{$key};
            my $value = $settings->{$key}; $value = $value->{value} if ref $value eq 'HASH';
            $selected{$key} = $value if defined $value && ((!ref $value && $value =~ /^[A-Za-z0-9_.-]{1,64}$/) || JSON::PP::is_bool($value));
        }
        $report->{docker}{configured_limits} = {status => 'observed', values => \%selected, note => 'Configured values may differ from the running Engine.'};
    }
    my $data = ref $settings eq 'HASH' ? $settings->{diskImageLocation} : undef;
    $data = ($ENV{HOME} // '').'/Library/Containers/com.docker.docker/Data/vms/0/data' unless defined $data && !ref $data && length $data;
    $report->{docker}{host_storage} = -d $data ? storage($data, 'docker_data') : {status => 'unavailable'};
    my $free = $report->{docker}{host_storage}{free_bytes} // $report->{storage}{free_bytes};
    check('disk_free', 'warning', 'Less than 10 GB free; the first build needs about 4 GB (HOW_TO_USE_Mac.html "1").') if defined $free && $free < 10_000_000_000;

    $report->{network} = {status => 'not_run', proxy_configured => ($ENV{HTTPS_PROXY} || $ENV{HTTP_PROXY} || $ENV{https_proxy} || $ENV{http_proxy}) ? JSON::PP::true : JSON::PP::false, checks => []};
    if ($network) {
        $report->{network}{status} = 'performed';
        for my $service (@{$profile{services}}) {
            my $n = execute('https_'.$service->[0], 12, '/usr/bin/curl', '--head', '--silent', '--show-error', '--connect-timeout', '5', '--max-time', '10', '--output', '/dev/null', '--write-out', '%{http_code}', $service->[1]);
            my $http = $n->{stdout} =~ /^(\d{3})$/ ? 0 + $1 : undef;
            my $ok = $n->{status} eq 'ok' && defined $http && $http >= 100 && $http < 600;
            push @{$report->{network}{checks}}, {service => $service->[0], status => $ok ? 'responded' : $n->{status}, http_status => $http,
                note => 'HTTP responses including 401 establish HTTPS reachability only, not package access or authentication.'};
            check('network_reachability', 'warning', 'A requested HTTPS check failed ('.$service->[0].').') unless $ok;
        }
        check('network_reachability', 'pass', 'Every image and package source responded over HTTPS (reachability only).') unless grep { $_->{status} ne 'responded' } @{$report->{network}{checks}};
    }
    $report->{share_test} = {status => 'not_run'};
    if ($share) {
        if (!$ready || $report->{docker}{image}{status} ne 'present') {
            $report->{share_test}{reason} = 'A responsive local Engine and an existing image are required; nothing is downloaded.';
            check('two_way_share', 'unknown', 'The requested sharing test was not run; start the launcher once so that the image exists.');
        }
        else {
            my $probe = $records_dir.'/.diagnostic-'.$run_id;
            my $container = 'launcher-diagnostic-'.$run_id;
            my $marker = 'launcher-diagnostic:'.$run_id;
            die 'Diagnostic probe path already exists.' if -e $probe;
            make_path($probe, {mode => 0700});
            open my $file, '>:raw', $probe.'/host.txt' or die 'Cannot create synthetic probe file.';
            print {$file} $marker."\n"; close $file;
            my $mount_path = $probe; $mount_path =~ s/"/""/g;
            my $test = execute('two_way_share', 30, $docker, 'run', '--rm', '--pull=never', '--name', $container,
                '--label', 'org.launcher.diagnostic.run='.$run_id, '--network', 'none', '--read-only', '--cap-drop', 'ALL', '--security-opt', 'no-new-privileges',
                '--entrypoint', '/bin/sh', '--env', 'LAUNCHER_DIAG_PROBE='.$marker, '--mount', 'type=bind,"source='.$mount_path.'",target=/diag', $report->{docker}{image}{details}{id},
                '-c', 'test "$(cat /diag/host.txt)" = "$LAUNCHER_DIAG_PROBE" && printf "%s\n" "$LAUNCHER_DIAG_PROBE" > /diag/container.txt');
            my $back = read_text($probe.'/container.txt');
            my $passed = $test->{status} eq 'ok' && defined $back && $back eq $marker."\n";
            my $cleaned = 1;
            if ($test->{status} eq 'timed_out') {
                my $owner = text('probe_owner', 10, $docker, 'container', 'inspect', $container, '--format', '{{index .Config.Labels "org.launcher.diagnostic.run"}}');
                $cleaned = defined $owner && $owner eq $run_id && execute('probe_cleanup', 10, $docker, 'container', 'rm', '--force', $container)->{status} eq 'ok';
            }
            if ($cleaned) { unlink $probe.'/host.txt'; unlink $probe.'/container.txt' if -f $probe.'/container.txt'; $cleaned = rmdir $probe; }
            $report->{share_test} = {status => $passed ? 'passed' : 'failed', cleanup_completed => $cleaned ? JSON::PP::true : JSON::PP::false, synthetic_data_only => JSON::PP::true};
            $report->{share_test}{cleanup_container} = $container unless $cleaned;
            check('two_way_share', $passed && $cleaned ? 'pass' : 'fail', 'Only new synthetic files and the uniquely labelled probe container are used.');
        }
    }
};
check('diagnostic_internal', 'unknown', clean($@)) if $@;

$report->{finished_at} = strftime('%Y-%m-%dT%H:%M:%SZ', gmtime);
$report->{elapsed_seconds} = 0 + sprintf('%.3f', clock_gettime(CLOCK_MONOTONIC) - $started);
my $failed = grep { $_->{status} eq 'fail' } @{$report->{checks}};
my $review = grep { $_->{status} eq 'unknown' || $_->{status} eq 'warning' } @{$report->{checks}};
$report->{overall} = $failed ? 'preparation_needed' : $review ? 'review_needed' : 'prerequisites_met';
my $leaf = 'environment_check_'.strftime('%Y%m%d_%H%M%S', gmtime).'_'.substr($run_id, 0, 8).'.json';
my $saved = eval {
    make_path($records_dir) unless -d $records_dir;
    open my $file, '>:raw', $records_dir.'/'.$leaf or die "Cannot save JSON.\n";
    print {$file} $json->encode($report);
    close $file or die "Cannot close JSON.\n"; 1;
};
my %overall_messages = $language eq 'ja' ?
    (prerequisites_met => '確かめた起動の条件を満たしています。', preparation_needed => '起動の前に準備が要ります（[fail] の行）。', review_needed => '確かめられなかった項目か、注意の要る項目があります（[unknown]・[warning] の行）。') :
    (prerequisites_met => 'Checked prerequisites are met.', preparation_needed => 'Preparation is needed before launch ([fail] lines).', review_needed => 'Some items need review or remain unverified ([unknown] / [warning] lines).');
print $overall_messages{$report->{overall}}."\n";
for my $item (@{$report->{routine_records}{entries} // []}) { print_routine_result($item); }
for my $item (@{$report->{checks}}) { print '['.$item->{status}.'] '.$item->{id}.': '.$item->{reason}."\n"; }
print $language eq 'ja' ? "解析そのものは確かめていません（".$profile{app}." の起動は start_mac.command で行います）。\n" : "The analysis itself was not tested (start ".$profile{app}." with start_mac.command).\n";
print $saved ? ($language eq 'ja' ? '結果を保存しました: ' : 'Saved the result: ').'outputs/launcher/'.$leaf."\n" : "ERROR: diagnostic JSON could not be saved.\n";
exit($saved ? $failed ? 2 : $review ? 3 : 0 : 1);
LAUNCHER_DIAGNOSTIC_PERL
