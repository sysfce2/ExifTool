#------------------------------------------------------------------------------
# File:         GoPro.pm
#
# Description:  Read information from GoPro videos
#
# Revisions:    2018/01/12 - P. Harvey Created
#
# References:   1) https://github.com/gopro/gpmf-parser
#               2) https://github.com/stilldavid/gopro-utils
#               3) https://github.com/gopro/gpmf-parser
#------------------------------------------------------------------------------

package Image::ExifTool::GoPro;

use strict;
use vars qw($VERSION);
use Image::ExifTool qw(:DataAccess :Utils);
use Image::ExifTool::QuickTime;

$VERSION = '1.14';

sub ProcessGoPro($$$);
sub ProcessString($$$);
sub ScaleValues($$);
sub AddUnits($$$);
sub ConvertSystemTime($$);

# GoPro data types that have ExifTool equivalents (ref 1)
my %goProFmt = ( # format codes
  # 0x00 - container (subdirectory)
    0x62 => 'int8s',    # 'b'
    0x42 => 'int8u',    # 'B'
    0x63 => 'string',   # 'c' (possibly null terminated)
    0x73 => 'int16s',   # 's'
    0x53 => 'int16u',   # 'S'
    0x6c => 'int32s',   # 'l'
    0x4c => 'int32u',   # 'L'
    0x66 => 'float',    # 'f'
    0x64 => 'double',   # 'd'
    0x46 => 'undef',    # 'F' (4-char ID)
    0x47 => 'undef',    # 'G' (16-byte uuid)
    0x6a => 'int64s',   # 'j'
    0x4a => 'int64u',   # 'J'
    0x71 => 'fixed32s', # 'q'
    0x51 => 'fixed64s', # 'Q'
    0x55 => 'undef',    # 'U' (16-byte date)
    0x3f => 'undef',    # '?' (complex structure)
);

# sizes of format codes if different than what FormatSize() would return
my %goProSize = (
    0x46 => 4,
    0x47 => 16,
    0x55 => 16,
);

# tagInfo elements to add units to PrintConv value
my %addUnits = (
    AddUnits => 1,
    PrintConv => 'Image::ExifTool::GoPro::AddUnits($self, $val, $tag)',
);

my %noYes = ( N => 'No', Y => 'Yes' );

# Tags found in the GPMF box of Hero6 mp4 videos (ref PH), and
# the gpmd-format timed metadata of Hero5 and Hero6 videos (ref 1)
%Image::ExifTool::GoPro::GPMF = (
    PROCESS_PROC => \&ProcessGoPro,
    GROUPS => { 2 => 'Camera' },
    NOTES => q{
        Tags extracted from the GPMF box of GoPro MP4 videos, the APP6 "GoPro"
        segment of JPEG files, and from the "gpmd" timed metadata if the
        L<ExtractEmbedded|../ExifTool.html#ExtractEmbedded> (-ee) option is enabled.  Many more tags exist, but are
        currently unknown and extracted only with the L<Unknown|../ExifTool.html#Unknown> (-u) option. Please
        let me know if you discover the meaning of any of these unknown tags. See
        L<https://github.com/gopro/gpmf-parser> for details about this format.
    },
    ABSC => 'AutoBoostScore', #3
    ACCL => { #2 (gpmd)
        Name => 'Accelerometer',
        Notes => 'accelerator readings in m/s2',
        Binary => 1,
    },
  # ANGX (GPMF-GEOC) - seen -0.05 (fmt d, Max)
  # ANGY (GPMF-GEOC) - seen 179.9 (fmt d, Max)
  # ANGZ (GPMF-GEOC) - seen 0.152 (fmt d, Max)
    ALLD => 'AutoLowLightDuration', #1 (gpmd) (untested)
    APTO => 'AudioProtuneOption', #3
    ARUW => 'AspectRatioUnwarped', #3
    ARWA => 'AspectRatioWarped', #3
    ATTD => { #PH (Karma)
        Name => 'Attitude',
        # UNIT=s,rad,rad,rad,rad/s,rad/s,rad/s,
        # TYPE=LffffffB
        # SCAL=1000 1 1 1 1 1 1 1
        Binary => 1,
    },
    ATTR => { #PH (Karma)
        Name => 'AttitudeTarget',
        # UNIT=s,rad,rad,rad,
        # TYPE=Jffff
        # SCAL=1000 1 1 1 1
        Binary => 1,
    },
    AUBT => { Name => 'AudioBlueTooth', PrintConv => \%noYes }, #3
    AUDO => 'AudioSetting', #PH (GPMF - seen: 'WIND', fmt c)
    AUPT => { Name => 'AutoProtune', PrintConv => \%noYes },
    BITR => 'BitrateSetting', #3
    BPOS => { #PH (Karma)
        Name => 'Controller',
        Unknown => 1,
        # UNIT=deg,deg,m,deg,deg,m,m,m
        # TYPE=lllfffff
        # SCAL=10000000 10000000 1000 1 1 1 1 1
        %addUnits,
    },
  # BRID (GPMF) - seen: 0 (fmt B)
  # BROD (GPMF) - seen: 'ASK','' (fmt c)
  # CALH (GPMF-GEOC) - seen 3040 (fmt L, Max)
  # CALW (GPMF-GEOC) - seen 4056 (fmt L, Max)
    CASN => 'CameraSerialNumber', #PH (GPMF - seen: 'C3221324545448', fmt c)
    CDAT => { #3
        Name => 'CreationDate',
        Groups => { 2 => 'Time' },
        RawConv => 'ConvertUnixTime($val)',
        PrintConv => '$self->ConvertDateTime($val)',
    },
    CDTM => 'CaptureDelayTimer', #3
  # CINF (GPMF) - seen: 0x67376be7709bc8876a8baf3940908618, 0xe230988539b30cf5f016627ae8fc5395,
  #                     0x8bcbe424acc5b37d7d77001635198b3b (fmt B) (Camera INFormation?)
    CLDP => { Name => 'ClassificationDataPresent', PrintConv => \%noYes },
  # CLKC (GPMF) - seen: 0 (fmt L)
  # CLKS (GPMF) - seen: 2 (fmt B)
  # CMOD (GPMF) - seen: 12,13,17 [12 360 video, 13 time-laps video, 17 JPEG] (fmt B) - CameraMode (ref 3)
  # CPID (GPMF) - seen: '1194885996 3387225026 733916448 2433577768' (fmt L)
  # CPIN (GPMF) - seen: 1
    CPIN => 'ChapterNumber',
  # CRTX (GPMF-BACK/FRNT) - double[1]
  # CRTY (GPMF-BACK/FRNT) - double[1]
    CSEN => { #PH (Karma)
        Name => 'CoyoteSense',
        # UNIT=s,rad/s,rad/s,rad/s,g,g,g,,,,
        # TYPE=LffffffLLLL
        # SCAL=1000 1 1 1 1 1 1 1 1 1 1
        Binary => 1,
    },
    CTRL => 'ControlLevel', #3
    CYTS => { #PH (Karma)
        Name => 'CoyoteStatus',
        # UNIT=s,,,,,rad,rad,rad,,
        # TYPE=LLLLLfffBB
        # SCAL=1000 1 1 1 1 1 1 1 1 1
        Binary => 1,
    },
    DEVC => { #PH (gpmd,GPMF, fmt \0)
        Name => 'DeviceContainer',
        SubDirectory => { TagTable => 'Image::ExifTool::GoPro::GPMF' },
        # (Max) DVID=1,DVNM='Global Settings',VERS,FMWR,LINF,CINF,CASN,MINF,MUID,CMOD,MTYP,OREN,
        #       DZOM,DZST,SMTR,PRTN,PTWB,PTSH,PTCL,EXPT,PIMX,PIMN,PTEV,RATE,SROT,ZFOV,VLTE,VLTA,
        #       EISE,EISA,AUPT,AUDO,BROD,BRID,PVUL,PRJT,SOFF
        # (Max) DVID='GEOC',DVNM='Geometry Calibrations',SHFX,SHFY,SHFZ,ANGX,ANGY,ANGZ,CALW,CALH
        # (Max) DVID='BACK',DVNM='Back Lens',KLNS,CTRX,CTRY,MFOV,SFTR
        # (Max) DVID='FRNT',DVNM='Front Lens',KLNS,CTRX,CTRY,MFOV,SFTR
        # (Max) DVID='HLMT',DVNM='Highlights'
    },
  # DNSC (GPMF) - seen: 'HIGH' (fmt c)
    DUST => 'DurationSetting', #3
  # DVID (GPMF) - DeviceID; seen: 1 (fmt L), HLMT (fmt F), GEOC (fmt F), 'BACK' (fmt F, Max)
    DVID => { Name => 'DeviceID', Unknown => 1 }, #2 (gpmd)
  # DVNM (GPMF) seen: 'Video Global Settings' (fmt c), 'Highlights' (fmt c), 'Geometry Calibrations' (Max)
  # DVNM (gpmd) seen: 'Camera' (Hero5), 'Hero6 Black' (Hero6), 'GoPro Karma v1.0' (Karma)
    DVNM => 'DeviceName', #PH (n/c)
    DZOM => { #PH (GPMF - seen: 'Y', fmt c)
        Name => 'DigitalZoomOn',
        PrintConv => \%noYes,
    },
    DZMX => 'DigitalZoomAmount', #3
    DZST => 'DigitalZoom', #3
    EISA => { #PH (GPMF) - seen: 'Y','N','HS EIS','N/A' (fmt c) [N was for a time-lapse video]
        Name => 'ElectronicImageStabilization',
    },
    EISE => { Name => 'ElectronicStabilizationOn', PrintConv => \%noYes }, #3
    EMPT => { Name => 'Empty', Unknown => 1 }, #2 (gpmd)
    ESCS => { #PH (Karma)
        Name => 'EscapeStatus',
        # UNIT=s,rpm,rpm,rpm,rpm,rpm,rpm,rpm,rpm,degC,degC,degC,degC,V,V,V,V,A,A,A,A,,,,,,,,,
        # TYPE=JSSSSSSSSssssSSSSSSSSSSSSSSSSB
        # (no SCAL!)
        Unknown => 1,
        %addUnits,
    },
    EXPT => 'ExposureType', #3
    FACE => 'FaceDetected', #PH (gpmd)
    FCNM => 'FaceNumbers', #PH (gpmd) (faces counted per frame, ref 1)
    FMWR => 'FirmwareVersion', #PH (GPMF - seen: HD6.01.01.51.00, fmt c)
    FWVS => 'OtherFirmware', #PH (NC) (gpmd - seen: '1.1.11.0', Karma)
    GLPI => { #PH (gpmd, Karma)
        Name => 'GPSPos',
        # UNIT=s,deg,deg,m,m,m/s,m/s,m/s,deg
        # TYPE=LllllsssS
        # SCAL=1000 10000000 10000000 1000 1000 100 100 100 100
        RawConv => '$val', # necessary to use scaled value instead of raw data as subdir data
        SubDirectory => { TagTable => 'Image::ExifTool::GoPro::GLPI' },
    },
    GPRI => { #PH (gpmd, Karma)
        Name => 'GPSRaw',
        # UNIT=s,deg,deg,m,m,m,m/s,deg,,
        # TYPE=JlllSSSSBB
        # SCAL=1000000,10000000,10000000,1000,100,100,100,100,1,1
        Unknown => 1,
        RawConv => '$val', # necessary to use scaled value instead of raw data as subdir data
        SubDirectory => { TagTable => 'Image::ExifTool::GoPro::GPRI' },
    },
    GPS5 => { #2 (gpmd)
        Name => 'GPSInfo',
        # UNIT=deg,deg,m,m/s,m/s
        # TYPE=l
        # SCAL=10000000,10000000,1000,1000,100
        RawConv => '$val', # necessary to use scaled value instead of raw data as subdir data
        SubDirectory => { TagTable => 'Image::ExifTool::GoPro::GPS5' },
    },
    GPS9 => { #PH (gpmd, Hero 13)
        Name => 'GPSInfo9',
        # UNIT=deg,deg,m,m/s,m/s,,s,,
        # TYPE=lllllllSS
        # SCAL=10000000 10000000 1000 1000 100 1 1000 100 1
        RawConv => '$val', # necessary to use scaled value instead of raw data as subdir data
        SubDirectory => { TagTable => 'Image::ExifTool::GoPro::GPS9' },
    },
    GPSF => { #2 (gpmd)
        Name => 'GPSMeasureMode',
        PrintConv => {
            2 => '2-Dimensional Measurement',
            3 => '3-Dimensional Measurement',
        },
    },
    GPSP => { #2 (gpmd)
        Name => 'GPSHPositioningError',
        Description => 'GPS Horizontal Positioning Error',
        ValueConv => '$val / 100', # convert from cm to m
    },
    GPSU => { #2 (gpmd)
        Name => 'GPSDateTime',
        Groups => { 2 => 'Time' },
        # (HERO5 writes this in 'c' format, HERO6 writes 'U')
        ValueConv => '$val =~ s/^(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})/20$1:$2:$3 $4:$5:/; $val',
        PrintConv => '$self->ConvertDateTime($val)',
    },
    GYRO => { #2 (gpmd)
        Name => 'Gyroscope',
        Notes => 'gyroscope readings in rad/s',
        Binary => 1,
    },
    HCLT => 'HorizonControl', #3
    HDRV => { Name => 'HDRVideo', PrintConv => \%noYes }, #3/PH (NC)
  # HFLG (APP6) - seen: 0
    HSGT => 'HindsightSettings', #3
    ISOE => 'ISOSpeeds', #PH (gpmd)
    ISOG => { #2 (gpmd)
        Name => 'ImageSensorGain',
        Binary => 1,
    },
    KBAT => { #PH (gpmd) (Karma)
        Name => 'BatteryStatus',
        # UNIT=A,Ah,J,degC,V,V,V,V,s,%,,,,,%
        # TYPE=lLlsSSSSSSSBBBb
        # SCAL=1000,1000,0.00999999977648258,100,1000,1000,1000,1000,0.0166666675359011,1,1,1,1,1,1
        RawConv => '$val', # necessary to use scaled value instead of raw data as subdir data
        SubDirectory => { TagTable => 'Image::ExifTool::GoPro::KBAT' },
    },
  # KLNS (GPMF-BACK/FRNT) - double[5] (fmt d, Max)
  # LINF (GPMF) - seen: LAJ7061916601668,C3341326002180,C33632245450981 (fmt c) (Lens INFormation?)
  # LMOD (GPMF) - seen: 'NONE' (fmt F)
    LNED => { #PH (Karma)
        Name => 'LocalPositionNED',
        # UNIT=s,m,m,m,m/s,m/s,m/s
        # TYPE=Lffffff
        # SCAL=1000 1 1 1 1 1 1
        Binary => 1,
    },
    MAGN => 'Magnetometer', #1 (gpmd) (units of uT)
    MAPX => 'MappingXCoefficients', #3
    MAPY => 'MappingYCoefficients', #3
  # MFOV (GPMF-BACK/FRNT) - seen: 100 (fmt d, Max)
    MINF => { #PH (GPMF - seen: HERO6 Black, fmt c)
        Name => 'Model',
        Groups => { 2 => 'Camera' },
        Description => 'Camera Model Name',
    },
    MMOD => 'MediaMode', #3
  # MTYP (GPMF) - seen: 0,1,5,11 [1 for time-lapse video, 5 for 360 video, 11 for JPEG] (fmt B) - MediaType (ref 3)
    MUID => { Name => 'MediaUID', ValueConv => 'join("-", unpack("H8H4H4H4H12", $val))' },
    MXCF => 'MappingXMode', #3
    MYCF => 'MappingYMode', #3
    ORDP => { Name => 'OrientationDataPresent', PrintConv => \%noYes }, #3
    OREN => { #PH (GPMF - seen: 'U', fmt c)
        Name => 'AutoRotation',
        PrintConv => {
            U => 'Up',
            D => 'Down', # (NC)
            A => 'Auto', # (NC)
        },
    },
    # (most of the "P" tags are Protune settings - PH)
    PHDR => 'HDRSetting', #PH (APP6 - seen: 0)
    PIMD => 'ProtuneISOMode', #3
    PIMN => 'AutoISOMin', #PH (GPMF - seen: 100, fmt L)
    PIMX => 'AutoISOMax', #PH (GPMF - seen: 1600, fmt L)
    POLY => 'PolynomialCoefficients', #3
  # PRAW (APP6) - seen: 0, 'N', 'Y' (fmt c)
  # PRCN (GPMF) - seen: 65 zeros (fmt B)
    PRES => 'PhotoResolution', #PH (APP6 - seen: '12MP_W')
    PRJT => 'LensProjection', #3
  # PRNA (GPMF) - seen 10 (fmt B) - PresetIDs (ref 3)
  # PRNU (GPMF) - seen 0 (fmt B) - PresetIDs (ref 3)
    PRTN => { #PH (GPMF - seen: 'N', fmt c)
        Name => 'Protune',
        PrintConv => {
            N => 'Off',
            Y => 'On', # (NC)
        },
    },
    PTCL => 'ColorMode', #PH (GPMF - seen: 'GOPRO', fmt c' APP6: 'FLAT')
    PTEV => 'ExposureCompensation', #PH (GPMF - seen: '0.0', fmt c)
    PTSH => 'Sharpness', #PH (GPMF - seen: 'HIGH', fmt c)
    PTWB => 'WhiteBalance', #PH (GPMF - seen: 'AUTO', fmt c)
  # PVUL (APP6) - seen: 'F' (fmt c, Hero8, Max)
    PWPR => 'PowerProfile', #3
    PYCF => 'PolynomialPower', #3
    RAMP => 'SpeedRampSetting', #3
    RATE => 'Rate', #PH (GPMF - seen: '0_5SEC', fmt c; APP6 - seen: '4_1SEC')
    RMRK => { #2 (gpmd)
        Name => 'Comments',
        ValueConv => '$self->Decode($val, "Latin")',
    },
    SCAL => { #2 (gpmd) scale factor for subsequent data
        Name => 'ScaleFactor',
        Unknown => 1,
    },
    SCAP => { Name => 'ScheduleCapture', PrintConv => \%noYes }, #3
    SCPR => { #PH (Karma) [stream was empty]
        Name => 'ScaledPressure',
        # UNIT=s,Pa,Pa,degC
        # TYPE=Lffs
        # SCAL=1000 0.00999999977648258 0.00999999977648258 100
        %addUnits,
    },
    SCTM => 'ScheduleCaptureTime', #3 (seconds since UTC midnight)
  # SFTR (GPMF-BACK/FRNT) - seen 0.999,1.00004 (fmt d, Max)
  # SHFX (GPMF-GEOC) - seen 22.92 (fmt d, Max)
  # SHFY (GPMF-GEOC) - seen 0.123 (fmt d, Max)
  # SHFZ (GPMF-GEOC) - seen 36.06 (fmt d, Max)
    SHUT => { #2 (gpmd)
        Name => 'ExposureTimes',
        PrintConv => q{
            my @a = split ' ', $val;
            $_ = Image::ExifTool::Exif::PrintExposureTime($_) foreach @a;
            return join ' ', @a;
        },
    },
    SIMU => { #PH (Karma)
        Name => 'ScaledIMU',
        # UNIT=s,g,g,g,rad/s,rad/s,rad/s,T,T,T
        # TYPE=Lsssssssss
        # SCAL=1000 1000 1000 1000 1000 1000 1000 1000 1000 1000
        %addUnits,
    },
    SIUN => { #2 (gpmd - seen : 'm/s2','rad/s')
        Name => 'SIUnits',
        Unknown => 1,
        ValueConv => '$self->Decode($val, "Latin")',
    },
    SMTR => { Name => 'SpotMeter', PrintConv => \%noYes }, #3
  # SOFF (APP6) - seen: 0 (fmt L, Hero8, Max)
    SROT => 'SensorReadoutTime', #3
    STMP => { #1 (gpmd)
        Name => 'TimeStamp',
        ValueConv => '$val / 1e6',
    },
    STRM => { #2 (gpmd,GPMF, fmt \0)
        Name => 'NestedSignalStream',
        SubDirectory => { TagTable => 'Image::ExifTool::GoPro::GPMF' },
    },
    STNM => { #2 (gpmd)
        Name => 'StreamName',
        Unknown => 1,
        ValueConv => '$self->Decode($val, "Latin")',
    },
    SYST => { #PH (Karma)
        Name => 'SystemTime',
        # UNIT=s,s
        # TYPE=JJ
        # SCAL=1000000 1000
        # save system time calibrations for later
        RawConv => q{
            my @v = split ' ', $val;
            if (@v == 2) {
                my $s = $$self{SystemTimeList};
                $s or $s = $$self{SystemTimeList} = [ ];
                push @$s, \@v;
            }
            return $val;
        },
    },
  # TICK => { Name => 'InTime', Unknown => 1, ValueConv => '$val/1000' }, #1 (gpmd)
    TMPC => { #2 (gpmd)
        Name => 'CameraTemperature',
        PrintConv => '"$val C"',
    },
  # TOCK => { Name => 'OutTime', Unknown => 1, ValueConv => '$val/1000' }, #1 (gpmd)
    TSMP => { Name => 'TotalSamples', Unknown => 1 }, #2 (gpmd)
    TYPE => { Name => 'StructureType', Unknown => 1 }, #2 (gpmd,GPMF - eg 'LLLllfFff', fmt c)
    TZON => { # (GPMF) - seen: 60 (fmt s)
        Name => 'TimeZone',
        PrintConv => 'Image::ExifTool::TimeZoneString($val)',
    },
    UNIT => { #2 (gpmd) alternative units
        Name => 'Units',
        Unknown => 1,
        ValueConv => '$self->Decode($val, "Latin")',
    },
    VERS => {
        Name => 'MetadataVersion',
        PrintConv => '$val =~ tr/ /./; $val',
    },
    VFOV => { #PH (GPMF - seen: 'W', fmt c)
        Name => 'FieldOfView',
        PrintConv => {
            W => 'Wide',
            S => 'Super View', # (NC, not seen)
            L => 'Linear', # (NC, not seen)
        },
    },
  # VLTA (GPMF) - seen: 78 ('N') (fmt B -- wrong format?)
    VFPS => { Name => 'VideoFrameRate', PrintConv => '$val=~s( )(/);$val' }, #PH (GPMF, fmt L)
    VFRH => { #PH (Karma)
        Name => 'VisualFlightRulesHUD',
        BinaryData => 1,
        # UNIT=m/s,m/s,m,m/s,deg,%
        # TYPE=ffffsS
    },
  # VLTE (GPMF) - seen: 'Y','N' (fmt c)
    VRES => { Name => 'VideoFrameSize', PrintConv => '$val=~s/ /x/;$val' }, #PH (GPMF, fmt L)
    WBAL => 'ColorTemperatures', #PH (gpmd)
    WRGB => { #PH (gpmd)
        Name => 'WhiteBalanceRGB',
        Binary => 1,
    },
    ZFOV => 'DiagonalFieldOfView', #3
    ZMPL => 'ZoomScaleNormalization', #3
#
# the following ref forum12825
#
    MUID => {
        Name => 'MediaUniqueID',
        PrintConv => q{
            my @a = split ' ', $val;
            $_ = sprintf('%.8x',$_) foreach @a;
            return join('', @a);
        },
    },
    MTRX => 'AccelerometerMatrix',
    ORIN => 'InputOrientation',
    ORIO => 'OutputOrientation',
    UNIF => 'InputUniformity',
    SROT => 'SensorReadoutTime',
    # the following are ref https://exiftool.org/forum/index.php?topic=15517.0
    CORI => { Name => 'CameraOrientation', Binary => 1, Notes => 'quaternions 0-1' },
    AALP => { Name => 'AudioLevel', Notes => 'dBFS' },
    GPSA => 'GPSAltitudeSystem', # (eg. 'MSLV')
    GRAV => { Name => 'GravityVector', Binary => 1 },
    HUES => 'PrediminantHue',
    IORI => { Name => 'ImageOrientation', Binary => 1, Notes => 'quaternions 0-1' },
    # LRVO - ? Part of LRV Frame Skip
    # LRVS - ? Part of LRV Frame Skip
    # LSKP - LRV Frame Skip
    # MSKP - MRV Frame Skip
    MWET => 'MicrophoneWet',
    SCEN => 'SceneClassification', # (SNOW,URBA,INDO,WATR,VEGE,BEAC + probability)
    WNDM => 'WindProcessing',
    YAVG => 'LumaAverage',
);

# GoPro GPS5 tags (ref 2) (Hero5,Hero6,Hero9)
%Image::ExifTool::GoPro::GPS5 = (
    PROCESS_PROC => \&ProcessString,
    GROUPS => { 1 => 'GoPro', 2 => 'Location' },
    VARS => { HEX_ID => 0, ID_LABEL => 'Index' },
    0 => { # (unit='deg')
        Name => 'GPSLatitude',
        PrintConv => 'Image::ExifTool::GPS::ToDMS($self, $val, 1, "N")',
    },
    1 => { # (unit='deg')
        Name => 'GPSLongitude',
        PrintConv => 'Image::ExifTool::GPS::ToDMS($self, $val, 1, "E")',
    },
    2 => { # (unit='m')
        Name => 'GPSAltitude',
        PrintConv => '"$val m"',
    },
    3 => {
        Name => 'GPSSpeed',
        Notes => 'stored as m/s but converted to km/h when extracted',
        ValueConv => '$val * 3.6',
    },
    4 => {
        Name => 'GPSSpeed3D',
        Notes => 'stored as m/s but converted to km/h when extracted',
        ValueConv => '$val * 3.6',
    },
);

# GoPro GPS9 tags (Hero13)
%Image::ExifTool::GoPro::GPS9 = (
    PROCESS_PROC => \&ProcessString,
    GROUPS => { 1 => 'GoPro', 2 => 'Location' },
    VARS => { HEX_ID => 0, ID_LABEL => 'Index' },
    0 => { # (unit='deg')
        Name => 'GPSLatitude',
        PrintConv => 'Image::ExifTool::GPS::ToDMS($self, $val, 1, "N")',
    },
    1 => { # (unit='deg')
        Name => 'GPSLongitude',
        PrintConv => 'Image::ExifTool::GPS::ToDMS($self, $val, 1, "E")',
    },
    2 => { # (unit='m')
        Name => 'GPSAltitude',
        PrintConv => '"$val m"',
    },
    3 => {
        Name => 'GPSSpeed',
        Notes => 'stored as m/s but converted to km/h when extracted',
        ValueConv => '$val * 3.6',
    },
    4 => {
        Name => 'GPSSpeed3D',
        Notes => 'stored as m/s but converted to km/h when extracted',
        ValueConv => '$val * 3.6',
    },
    5 => { # days since 2000
        Name => 'GPSDays',
        RawConv => '$$self{GPSDays} = $val; undef',
        Hidden => 1,
    },
    6 => { # seconds of date/time
        Name => 'GPSDateTime',
        Groups => { 2 => 'Time' },
        # (10957 days from Jan 1 1970 to Jan 1 2000)
        RawConv => 'ConvertUnixTime(($$self{GPSDays} + 10957) * 24 * 3600 + $val, undef, 3)',
        PrintConv => '$self->ConvertDateTime($val)',
    },
    7 => 'GPSDOP',
    8 => {
        Name => 'GPSMeasureMode', #PH (NC)
        PrintConv => {
            2 => '2-Dimensional Measurement',
            3 => '3-Dimensional Measurement',
        },
    },
);

# GoPro GPRI tags (ref PH) (Karma)
%Image::ExifTool::GoPro::GPRI = (
    PROCESS_PROC => \&ProcessString,
    GROUPS => { 1 => 'GoPro', 2 => 'Location' },
    VARS => { HEX_ID => 0, ID_LABEL => 'Index' },
    0 => { # (unit='s')
        Name => 'GPSDateTimeRaw',
        Groups => { 2 => 'Time' },
        ValueConv => \&ConvertSystemTime,   # convert to date/time based on SystemTime clock
        PrintConv => '$self->ConvertDateTime($val)',
    },
    1 => { # (unit='deg')
        Name => 'GPSLatitudeRaw',
        PrintConv => 'Image::ExifTool::GPS::ToDMS($self, $val, 1, "N")',
    },
    2 => { # (unit='deg')
        Name => 'GPSLongitudeRaw',
        PrintConv => 'Image::ExifTool::GPS::ToDMS($self, $val, 1, "E")',
    },
    3 => {
        Name => 'GPSAltitudeRaw', # (NC)
        PrintConv => '"$val m"',
    },
    # (unknown tags must be defined so that ProcessString() will iterate through all values)
    4 => { Name => 'GPRI_Unknown4', Unknown => 1, Hidden => 1, PrintConv => '"$val m"' },
    5 => { Name => 'GPRI_Unknown5', Unknown => 1, Hidden => 1, PrintConv => '"$val m"' },
    6 => 'GPSSpeedRaw', # (NC) # (unit='m/s' -- should convert to other units?)
    7 => 'GPSTrackRaw', # (NC) # (unit='deg')
    8 => { Name => 'GPRI_Unknown8', Unknown => 1, Hidden => 1 }, # (no units)
    9 => { Name => 'GPRI_Unknown9', Unknown => 1, Hidden => 1 }, # (no units)
);

# GoPro GLPI tags (ref PH) (Karma)
%Image::ExifTool::GoPro::GLPI = (
    PROCESS_PROC => \&ProcessString,
    GROUPS => { 1 => 'GoPro', 2 => 'Location' },
    VARS => { HEX_ID => 0, ID_LABEL => 'Index' },
    0 => { # (unit='s')
        Name => 'GPSDateTime',
        Groups => { 2 => 'Time' },
        ValueConv => \&ConvertSystemTime,   # convert to date/time based on SystemTime clock
        PrintConv => '$self->ConvertDateTime($val)',
    },
    1 => { # (unit='deg')
        Name => 'GPSLatitude',
        PrintConv => 'Image::ExifTool::GPS::ToDMS($self, $val, 1, "N")',
    },
    2 => { # (unit='deg')
        Name => 'GPSLongitude',
        PrintConv => 'Image::ExifTool::GPS::ToDMS($self, $val, 1, "E")',
    },
    3 => { # (unit='m')
        Name => 'GPSAltitude', # (NC)
        PrintConv => '"$val m"',
    },
    # (unknown tags must be defined so that ProcessString() will iterate through all values)
    4 => { Name => 'GLPI_Unknown4', Unknown => 1, Hidden => 1, PrintConv => '"$val m"' },
    5 => { Name => 'GPSSpeedX', PrintConv => '"$val m/s"' }, # (NC)
    6 => { Name => 'GPSSpeedY', PrintConv => '"$val m/s"' }, # (NC)
    7 => { Name => 'GPSSpeedZ', PrintConv => '"$val m/s"' }, # (NC)
    8 => { Name => 'GPSTrack' }, # (unit='deg')
);

# GoPro KBAT tags (ref PH)
%Image::ExifTool::GoPro::KBAT = (
    PROCESS_PROC => \&ProcessString,
    GROUPS => { 1 => 'GoPro', 2 => 'Camera' },
    VARS => { HEX_ID => 0, ID_LABEL => 'Index' },
    NOTES => 'Battery status information found in GoPro Karma videos.',
     0 => { Name => 'BatteryCurrent',  PrintConv => '"$val A"' },
     1 => { Name => 'BatteryCapacity', PrintConv => '"$val Ah"' },
     2 => { Name => 'KBAT_Unknown2',   PrintConv => '"$val J"', Unknown => 1, Hidden => 1 },
     3 => { Name => 'BatteryTemperature', PrintConv => '"$val C"' },
     4 => { Name => 'BatteryVoltage1', PrintConv => '"$val V"' },
     5 => { Name => 'BatteryVoltage2', PrintConv => '"$val V"' },
     6 => { Name => 'BatteryVoltage3', PrintConv => '"$val V"' },
     7 => { Name => 'BatteryVoltage4', PrintConv => '"$val V"' },
     8 => { Name => 'BatteryTime',     PrintConv => 'ConvertDuration(int($val + 0.5))' }, # (NC)
     9 => { Name => 'KBAT_Unknown9',   PrintConv => '"$val %"', Unknown => 1, Hidden => 1,  },
    10 => { Name => 'KBAT_Unknown10',  Unknown => 1, Hidden => 1 }, # (no units)
    11 => { Name => 'KBAT_Unknown11',  Unknown => 1, Hidden => 1 }, # (no units)
    12 => { Name => 'KBAT_Unknown12',  Unknown => 1, Hidden => 1 }, # (no units)
    13 => { Name => 'KBAT_Unknown13',  Unknown => 1, Hidden => 1 }, # (no units)
    14 => { Name => 'BatteryLevel',    PrintConv => '"$val %"' },
);

# GoPro fdsc tags written by the Hero5 and Hero6 (ref PH)
%Image::ExifTool::GoPro::fdsc = (
    GROUPS => { 2 => 'Camera' },
    PROCESS_PROC => \&Image::ExifTool::ProcessBinaryData,
    NOTES => q{
        Tags extracted from the MP4 "fdsc" timed metadata when the L<ExtractEmbedded|../ExifTool.html#ExtractEmbedded>
        (-ee) option is used.
    },
    0x08 => { Name => 'FirmwareVersion',    Format => 'string[15]' },
    0x17 => { Name => 'SerialNumber',       Format => 'string[16]' },
    0x57 => { Name => 'OtherSerialNumber',  Format => 'string[15]' }, # (NC)
    0x66 => {
        Name => 'Model',
        Description => 'Camera Model Name',
        Format => 'string[16]',
    },
    # ...
    # after this there are lots of interesting values also found in the GPMF box,
    # but this block is lacking tag ID's and any directory structure, so the
    # value offsets are therefore presumably firmware dependent :(
);

#------------------------------------------------------------------------------
# Convert system time to date/time string
# Inputs: 0) system time value, 1) ExifTool ref
# Returns: EXIF-format date/time string with milliseconds
sub ConvertSystemTime($$)
{
    my ($val, $et) = @_;
    my $s = $$et{SystemTimeList} or return '<uncalibrated>';
    unless ($$et{SystemTimeListSorted}) {
        $s = $$et{SystemTimeList} = [ sort { $$a[0] <=> $$b[0] } @$s ];
        $$et{SystemTimeListSorted} = 1;
    }
    my ($i, $j) = (0, $#$s);
    # perform binary search to find this system time value
    while ($j - $i > 1) {
        my $t = int(($i + $j) / 2);
        ($val < $$s[$t][0] ? $j : $i) = $t;
    }
    if ($i == $j or $$s[$j][0] == $$s[$i][0]) {
        $val = $$s[$i][1];
    } else {
        # interpolate between values
        $val = $$s[$i][1] + ($$s[$j][1] - $$s[$i][1]) * ($val - $$s[$i][0]) / ($$s[$j][0] - $$s[$i][0]);
    }
    # (a bit tricky to remove fractional seconds then add them back again after
    #  the date/time conversion while avoiding round-off errors which could
    #  put the seconds out by 1...)
    my ($t, $f) = ("$val" =~ /^(\d+)(\.\d+)/);
    return Image::ExifTool::ConvertUnixTime($t, $$et{OPTIONS}{QuickTimeUTC}) . $f;
}

#------------------------------------------------------------------------------
# Scale values by last 'SCAL' constants
# Inputs: 0) value or list of values, 1) string of scale factors
# Returns: nothing, but updates values
sub ScaleValues($$)
{
    my ($val, $scl) = @_;
    return unless $val and $scl;
    my @scl = split ' ', $scl or return;
    my @scaled;
    my $v = (ref $val eq 'ARRAY') ? $val : [ $val ];
    foreach $val (@$v) {
        my @a = split ' ', $val;
        $a[$_] /= $scl[$_ % @scl] foreach 0..$#a;
        push @scaled, join(' ', @a);
    }
    $_[0] = @scaled > 1 ? \@scaled : $scaled[0];
}

#------------------------------------------------------------------------------
# Add units to values for human-readable output
# Inputs: 0) ExifTool ref, 1) value, 2) tag key
# Returns: converted value
sub AddUnits($$$)
{
    my ($et, $val, $tag) = @_;
    if ($et and $$et{TAG_EXTRA}{$tag}{Units}) {
        my $u = $$et{TAG_EXTRA}{$tag}{Units};
        $u = [ $u ] unless ref $u eq 'ARRAY';
        my @a = split ' ', $val;
        if (@$u == @a) {
            my $i;
            for ($i=0; $i<@a; ++$i) {
                $a[$i] .= ' ' . $$u[$i] if $$u[$i];
            }
            $val = join ' ', @a;
        }
    }
    return $val;
}

#------------------------------------------------------------------------------
# Process string of values (or array of strings) to extract as separate tags
# Inputs: 0) ExifTool object ref, 1) directory information ref, 2) tag table ref
# Returns: 1 on success
sub ProcessString($$$)
{
    my ($et, $dirInfo, $tagTablePtr) = @_;
    my $dataPt = $$dirInfo{DataPt};
    my @list = ref $$dataPt eq 'ARRAY' ? @{$$dataPt} : ( $$dataPt );
    my ($string, $val);
    $et->VerboseDir('GoPro structure');
    my $docNum = $$et{DOC_NUM};
    my $subDoc = 0;
    foreach $string (@list) {
        my @val = split ' ', $string;
        my $i = 0;
        foreach $val (@val) {
            $et->HandleTag($tagTablePtr, $i, $val);
            next if $$tagTablePtr{++$i};
            # increment subdoc for records stored as string of values (eg. GPS5)
            $i = 0;
            ++$subDoc;
            $$et{DOC_NUM} = "$docNum-$subDoc";
        }
        if ($i) {
            # increment subdoc for records stored as array of strings (eg. GPS9)
            ++$subDoc;
            $$et{DOC_NUM} = "$docNum-$subDoc";
        }
    }
    $$et{DOC_NUM} = $docNum;
    return 1;
}

#------------------------------------------------------------------------------
# Process "GP\x06\0" records in MP4 'mdat' atom
# Inputs: 0) ExifTool object ref, 1) dirInfo ref (RAF and DirLen)
# Returns: size of GoPro record, or 0 on error
sub ProcessGP6($$)
{
    my ($et, $dirInfo) = @_;
    my $raf = $$dirInfo{RAF};
    my $len = $$dirInfo{DirLen};
    my $buff;
    while ($len > 16) {
        $raf->Read($buff, 16) == 16 or last;
        my ($tag, $size) = unpack('a4N', $buff);
        last if $size + 16 > $len or $buff !~ /^GP..\0/s;
        $raf->Read($buff, $size) == $size or last;
        if ($buff =~ /^DEVC/) {
            $$et{DOC_NUM} = ++$$et{DOC_COUNT};
            my $tagTbl = GetTagTable('Image::ExifTool::GoPro::GPMF');
            ProcessGoPro($et, { DataPt => \$buff, DataPos => $raf->Tell()-$size }, $tagTbl);
        }
        $len -= $size + 16;
    }
    delete $$et{DOC_NUM};
    return $$dirInfo{DirLen} - $len;
}

#------------------------------------------------------------------------------
# Process GoPro metadata (gpmd samples, GPMF box, or APP6) (ref PH/1/2)
# Inputs: 0) ExifTool object ref, 1) dirInfo ref, 2) tag table ref
# Returns: 1 on success
# - with hack to check for encrypted text in gpmd data (Rove Stealth 4K)
sub ProcessGoPro($$$)
{
    my ($et, $dirInfo, $tagTablePtr) = @_;
    my $dataPt = $$dirInfo{DataPt};
    my $base = $$dirInfo{Base};
    my $pos = $$dirInfo{DirStart} || 0;
    my $dirEnd = $pos + ($$dirInfo{DirLen} || (length($$dataPt) - $pos));
    my $verbose = $et->Options('Verbose');
    my $unknown = $verbose || $et->Options('Unknown');
    my ($size, $type, $unit, $scal, $setGroup0);

    $et->VerboseDir($$dirInfo{DirName} || 'GPMF', undef, $dirEnd-$pos) if $verbose;
    $$et{FoundEmbedded} = 1;
    if ($pos) {
        my $parent = $$dirInfo{Parent};
        $setGroup0 = $$et{SET_GROUP0} = 'APP6' if $parent and $parent eq 'APP6';
    } else {
        # set group0 to "QuickTime" unless group1 is being changed (to Track#)
        $setGroup0 = $$et{SET_GROUP0} = 'QuickTime' unless $$et{SET_GROUP1};
    }

    for (; $pos+8<=$dirEnd; $pos+=($size+3)&0xfffffffc) {
        my ($tag,$fmt,$len,$count) = unpack("x${pos}a4CCn", $$dataPt);
        if ($tag =~ /[^-_a-zA-Z0-9 ]/) {
            $et->Warn('Unrecognized GoPro record') unless $tag eq "\0\0\0\0";
            last;
        }
        $size = $len * $count;
        $pos += 8;
        if ($pos + $size > $dirEnd) {
            $et->Warn('Truncated GoPro record');
            last;
        }
        my $tagInfo = $et->GetTagInfo($tagTablePtr, $tag);
        last if $tag eq "\0\0\0\0";     # stop at null tag
        next unless $size or $verbose;  # don't save empty values unless verbose
        my $format = $goProFmt{$fmt} || 'undef';
        my ($val, $i, $j, $p, @v);
        if ($fmt == 0x3f and defined $type) {
            # decode structure with format given by previous 'TYPE'
            for ($i=0; $i<$count; ++$i) {
                my (@s, $l);
                for ($j=0, $p=0; $j<length($type); ++$j, $p+=$l) {
                    my $b = Get8u(\$type, $j);
                    my $f = $goProFmt{$b} or last;
                    $l = $goProSize{$b} || Image::ExifTool::FormatSize($f) or last;
                    last if $p + $l > $len;
                    my $s = ReadValue($dataPt, $pos+$i*$len+$p, $f, undef, $l);
                    last unless defined $s;
                    push @s, $s;
                }
                push @v, join ' ', @s if @s;
            }
            $val = @v > 1 ? \@v : $v[0];
        } elsif (($format eq 'undef' or $format eq 'string') and $count > 1 and $len > 1) {
            # unpack multiple undef/string values as a list
            my $a = $format eq 'undef' ? 'a' : 'A';
            $val = [ unpack("x${pos}".("$a$len" x $count), $$dataPt) ];
        } else {
            $val = ReadValue($dataPt, $pos, $format, undef, $size);
        }
        # save TYPE, UNIT/SIUN and SCAL values for later
        $type = $val if $tag eq 'TYPE';
        $unit = $val if $tag eq 'UNIT' or $tag eq 'SIUN';
        $scal = $val if $tag eq 'SCAL';

        unless ($tagInfo) {
            next unless $unknown;
            my $name = Image::ExifTool::QuickTime::PrintableTagID($tag);
            $tagInfo = { Name => "GoPro_$name", Description => "GoPro $name", Unknown => 1 };
            $$tagInfo{SubDirectory} = { TagTable => 'Image::ExifTool::GoPro::GPMF' } if not $fmt;
            AddTagToTable($tagTablePtr, $tag, $tagInfo);
        }
        # apply scaling if available to last tag in this container
        ScaleValues($val, $scal) if $scal and $tag ne 'SCAL' and $pos+$size+3>=$dirEnd;
        my $key = $et->HandleTag($tagTablePtr, $tag, $val,
            DataPt  => $dataPt,
            DataPos => $$dirInfo{DataPos},
            Base    => $base,
            Start   => $pos,
            Size    => $size,
            TagInfo => $tagInfo,
            Format  => $format,
            Extra   => $verbose ? ", type='".($fmt ? chr($fmt) : '\0')."' size=$len count=$count" : undef,
        );
        # save units for adding in print conversion if specified
        $$et{TAG_EXTRA}{$key}{Units} = $unit if $$tagInfo{AddUnits} and $key;
    }
    delete $$et{SET_GROUP0} if $setGroup0;
    return 1;
}

1;  # end

__END__

=head1 NAME

Image::ExifTool::GoPro - Read information from GoPro videos

=head1 SYNOPSIS

This module is used by Image::ExifTool

=head1 DESCRIPTION

This module contains definitions required by Image::ExifTool to decode
metadata from GoPro MP4 videos.

=head1 AUTHOR

Copyright 2003-2025, Phil Harvey (philharvey66 at gmail.com)

This library is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.

=head1 REFERENCES

=over 4

=item L<https://github.com/gopro/gpmf-parser>

=item L<https://github.com/stilldavid/gopro-utils>

=item L<https://github.com/gopro/gpmf-parser>

=back

=head1 SEE ALSO

L<Image::ExifTool::TagNames/GoPro Tags>,
L<Image::ExifTool(3pm)|Image::ExifTool>

=cut

