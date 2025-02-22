!> \brief Routines for computing combustion

MODULE FIRE

USE PRECISION_PARAMETERS
USE GLOBAL_CONSTANTS
USE MESH_POINTERS
USE COMP_FUNCTIONS, ONLY: CURRENT_TIME
USE SOOT_ROUTINES, ONLY: SOOT_SURFACE_OXIDATION
#ifdef WITH_SUNDIALS
USE CVODE_INTERFACE
#endif

IMPLICIT NONE (TYPE,EXTERNAL)


PRIVATE

REAL(EB), ALLOCATABLE, DIMENSION(:) :: DZ_F0
REAL(EB) :: RRTMP0,MOLPCM3
DOUBLE PRECISION, ALLOCATABLE, DIMENSION(:) :: ATOL,RTOL
LOGICAL :: CVODE_INIT=.FALSE.
INTEGER :: I0,J0,K0,NM0

PUBLIC COMBUSTION,COMBUSTION_BC,CONDENSATION_EVAPORATION,GET_FLAME_TEMPERATURE

CONTAINS

SUBROUTINE COMBUSTION(T,DT,NM)

USE SOOT_ROUTINES, ONLY: SOOT_SURFACE_OXIDATION
USE COMP_FUNCTIONS, ONLY: CURRENT_TIME
INTEGER, INTENT(IN) :: NM
REAL(EB), INTENT(IN) :: T,DT
INTEGER :: ICC,JCC
REAL(EB) :: TNOW

TNOW=CURRENT_TIME()

CALL POINT_TO_MESH(NM)


! Set CVODES options
IF (.NOT. CVODE_INIT) THEN
   CVODE_INIT = .TRUE.
   ALLOCATE(ATOL(N_TRACKED_SPECIES))
   ALLOCATE(RTOL(N_TRACKED_SPECIES))
ENDIF

Q     = 0._EB
CHI_R = 0._EB

IF (CC_IBM) THEN
   DO ICC=1,MESHES(NM)%N_CUTCELL_MESH
      DO JCC=1,CUT_CELL(ICC)%NCELL
         CUT_CELL(ICC)%Q(JCC)=0._EB
      ENDDO
   ENDDO
ENDIF

IF (N_REACTIONS==0) RETURN

IF (.NOT.ALL(REACTION%FAST_CHEMISTRY)) ALLOCATE(DZ_F0(N_REACTIONS))

! Call combustion ODE solver

CALL COMBUSTION_GENERAL(T,DT,NM)

! Soot oxidation routine

IF (DEPOSITION .AND. SOOT_OXIDATION) CALL SOOT_SURFACE_OXIDATION(DT,NM)

IF (ALLOCATED(DZ_F0)) DEALLOCATE(DZ_F0)

T_USED(10)=T_USED(10)+CURRENT_TIME()-TNOW

END SUBROUTINE COMBUSTION


SUBROUTINE COMBUSTION_GENERAL(T,DT,NM)

! Generic combustion routine for multi-step reactions

USE PHYSICAL_FUNCTIONS, ONLY: GET_SPECIFIC_GAS_CONSTANT,GET_MASS_FRACTION_ALL,GET_SPECIFIC_HEAT,GET_MOLECULAR_WEIGHT, &
                              GET_SENSIBLE_ENTHALPY_Z,IS_REALIZABLE
USE COMPLEX_GEOMETRY, ONLY : CC_CGSC, CC_GASPHASE
INTEGER :: I,J,K,NS,NR,N,CHEM_SUBIT_TMP, ICC, JCC, NCELL
REAL(EB), INTENT(IN) :: T,DT
INTEGER, INTENT(IN) :: NM
REAL(EB) :: ZZ_GET(1:N_TRACKED_SPECIES),DZZ(1:N_TRACKED_SPECIES),CP,H_S_N,&
            REAC_SOURCE_TERM_TMP(N_TRACKED_SPECIES),Q_REAC_TMP(N_REACTIONS),RSUM_LOC,VCELL,PRES
LOGICAL :: Q_EXISTS
TYPE (REACTION_TYPE), POINTER :: RN
TYPE (SPECIES_MIXTURE_TYPE), POINTER :: SM
LOGICAL :: DO_REACTION,REALIZABLE

Q_EXISTS =  .FALSE.

IF (REAC_SOURCE_CHECK) THEN
   REAC_SOURCE_TERM=0._EB
   Q_REAC=0._EB
   IF (CC_IBM) THEN
      DO ICC=1,MESHES(NM)%N_CUTCELL_MESH
         DO JCC=1,CUT_CELL(ICC)%NCELL
            CUT_CELL(ICC)%Q_REAC(:,JCC) = 0._EB
         ENDDO
      ENDDO
   ENDIF
ENDIF

DO K=1,KBAR
   DO J=1,JBAR
      ILOOP: DO I=1,IBAR
         ! Check to see if a reaction is possible
         IF (CELL(CELL_INDEX(I,J,K))%SOLID) CYCLE ILOOP
         IF (CC_IBM) THEN
            IF (CCVAR(I,J,K,CC_CGSC) /= CC_GASPHASE) CYCLE ILOOP
         ENDIF
         IF (.NOT.ALL(REACTION%FAST_CHEMISTRY) .AND. TMP(I,J,K) < FINITE_RATE_MIN_TEMP) CYCLE ILOOP
         ZZ_GET = ZZ(I,J,K,1:N_TRACKED_SPECIES)
         IF (CHECK_REALIZABILITY) THEN
            REALIZABLE=IS_REALIZABLE(ZZ_GET)
            IF (.NOT.REALIZABLE) THEN
               WRITE(LU_ERR,*) I,J,K
               WRITE(LU_ERR,*) ZZ_GET
               WRITE(LU_ERR,*) SUM(ZZ_GET)
               WRITE(LU_ERR,*) 'ERROR: Unrealizable mass fractions input to COMBUSTION_MODEL'
               STOP_STATUS=REALIZABILITY_STOP
               RETURN
            ENDIF
         ENDIF
         CALL CHECK_REACTION
         IF (.NOT.DO_REACTION) CYCLE ILOOP ! Check whether any reactions are possible.
         DZZ = ZZ_GET ! store old ZZ for divergence term
         NM0 = NM
         I0 = I
         J0 = J
         K0 = K
         !***************************************************************************************
         ! Call combustion integration routine for Cartesian cell (I,J,K)
         PRES = PBAR(K,PRESSURE_ZONE(I,J,K)) + RHO(I,J,K)*(H(I,J,K)-KRES(I,J,K))
         CALL COMBUSTION_MODEL( T,DT,ZZ_GET,Q(I,J,K),MIX_TIME(I,J,K),CHI_R(I,J,K),&
                                CHEM_SUBIT_TMP,REAC_SOURCE_TERM_TMP,Q_REAC_TMP,&
                                TMP(I,J,K),RHO(I,J,K),PRES, MU(I,J,K),&
                                LES_FILTER_WIDTH(I,J,K),DX(I)*DY(J)*DZ(K),IIC=I,JJC=J,KKC=K )
         !***************************************************************************************
         IF (STOP_STATUS/=NO_STOP) RETURN
         IF (OUTPUT_CHEM_IT) CHEM_SUBIT(I,J,K) = CHEM_SUBIT_TMP
         IF (REAC_SOURCE_CHECK) THEN ! Store special diagnostic quantities
            REAC_SOURCE_TERM(I,J,K,:) = REAC_SOURCE_TERM_TMP
            Q_REAC(I,J,K,:) = Q_REAC_TMP
         ENDIF
         IF (CHECK_REALIZABILITY) THEN
            REALIZABLE=IS_REALIZABLE(ZZ_GET)
            IF (.NOT.REALIZABLE) THEN
               WRITE(LU_ERR,*) ZZ_GET,SUM(ZZ_GET)
               WRITE(LU_ERR,*) 'ERROR: Unrealizable mass fractions after COMBUSTION_MODEL'
               STOP_STATUS=REALIZABILITY_STOP
               RETURN
            ENDIF
         ENDIF
         DZZ = ZZ_GET - DZZ
         ! Update RSUM and ZZ
         DZZ_IF: IF ( ANY(ABS(DZZ) > DZZ_CLIP) ) THEN
            IF (ABS(Q(I,J,K)) > TWO_EPSILON_EB) Q_EXISTS = .TRUE.
            ! Divergence term
            CALL GET_SPECIFIC_HEAT(ZZ_GET,CP,TMP(I,J,K))
            CALL GET_SPECIFIC_GAS_CONSTANT(ZZ_GET,RSUM_LOC)
            DO N=1,N_TRACKED_SPECIES
               SM => SPECIES_MIXTURE(N)
               CALL GET_SENSIBLE_ENTHALPY_Z(N,TMP(I,J,K),H_S_N)
               D_SOURCE(I,J,K) = D_SOURCE(I,J,K) + ( SM%RCON/RSUM_LOC - H_S_N/(CP*TMP(I,J,K)) )*DZZ(N)/DT
               M_DOT_PPP(I,J,K,N) = M_DOT_PPP(I,J,K,N) + RHO(I,J,K)*DZZ(N)/DT
            ENDDO
         ENDIF DZZ_IF
      ENDDO ILOOP
   ENDDO
ENDDO

CC_IBM_IF: IF (CC_IBM) THEN
   ICC_LOOP : DO ICC=1,MESHES(NM)%N_CUTCELL_MESH
      I     = CUT_CELL(ICC)%IJK(IAXIS)
      J     = CUT_CELL(ICC)%IJK(JAXIS)
      K     = CUT_CELL(ICC)%IJK(KAXIS)

      VCELL = DX(I)*DY(J)*DZ(K)

      IF (CELL(CELL_INDEX(I,J,K))%SOLID) CYCLE ICC_LOOP ! Cycle in case Cartesian cell inside OBSTS.

      NCELL = CUT_CELL(ICC)%NCELL
      JCC_LOOP : DO JCC=1,NCELL

         ! Drop if cut-cell is very small compared to Cartesian cells:
         IF ( ABS(CUT_CELL(ICC)%VOLUME(JCC)/VCELL) <  1.E-12_EB ) CYCLE JCC_LOOP
         IF (.NOT.ALL(REACTION%FAST_CHEMISTRY) .AND. CUT_CELL(ICC)%TMP(JCC) < FINITE_RATE_MIN_TEMP) CYCLE JCC_LOOP

         CUT_CELL(ICC)%CHI_R(JCC)    = 0._EB
         ZZ_GET = CUT_CELL(ICC)%ZZ(1:N_TRACKED_SPECIES,JCC)

         IF (CHECK_REALIZABILITY) THEN
            REALIZABLE=IS_REALIZABLE(ZZ_GET)
            IF (.NOT.REALIZABLE) THEN
               WRITE(LU_ERR,*) I,J,K
               WRITE(LU_ERR,*) ZZ_GET
               WRITE(LU_ERR,*) SUM(ZZ_GET)
               WRITE(LU_ERR,*) 'ERROR: Unrealizable mass fractions input to COMBUSTION_MODEL'
               STOP_STATUS=REALIZABILITY_STOP
            ENDIF
         ENDIF
         CALL CHECK_REACTION
         IF (.NOT.DO_REACTION) CYCLE ICC_LOOP ! Check whether any reactions are possible.

         DZZ = ZZ_GET ! store old ZZ for divergence term
         !***************************************************************************************
         ! Call combustion integration routine for CUT_CELL(ICC)%XX(JCC)
         PRES = PBAR(K,PRESSURE_ZONE(I,J,K)) + RHO(I,J,K)*(H(I,J,K)-KRES(I,J,K))
         ! Note AUTO_IGNITION_TEMPERATURE here will apply to all cut-cells in Cartesian cell, currently 1.
         CALL COMBUSTION_MODEL( T,DT,ZZ_GET,CUT_CELL(ICC)%Q(JCC),CUT_CELL(ICC)%MIX_TIME(JCC),&
                                CUT_CELL(ICC)%CHI_R(JCC),&
                                CHEM_SUBIT_TMP,REAC_SOURCE_TERM_TMP,Q_REAC_TMP,&
                                CUT_CELL(ICC)%TMP(JCC),CUT_CELL(ICC)%RHO(JCC),PRES,MU(I,J,K),&
                                LES_FILTER_WIDTH(I,J,K),CUT_CELL(ICC)%VOLUME(JCC),IIC=I,JJC=J,KKC=K)
         !***************************************************************************************
         IF (REAC_SOURCE_CHECK) THEN ! Store special diagnostic quantities
             CUT_CELL(ICC)%REAC_SOURCE_TERM(1:N_TRACKED_SPECIES,JCC)=REAC_SOURCE_TERM_TMP(1:N_TRACKED_SPECIES)
             CUT_CELL(ICC)%Q_REAC(1:N_REACTIONS,JCC)=Q_REAC_TMP(1:N_REACTIONS)
         ENDIF

         IF (CHECK_REALIZABILITY) THEN
            REALIZABLE=IS_REALIZABLE(ZZ_GET)
            IF (.NOT.REALIZABLE) THEN
               WRITE(LU_ERR,*) ZZ_GET,SUM(ZZ_GET)
               WRITE(LU_ERR,*) 'ERROR: Unrealizable mass fractions after COMBUSTION_MODEL'
               STOP_STATUS=REALIZABILITY_STOP
            ENDIF
         ENDIF

         DZZ = ZZ_GET - DZZ

         ! Update RSUM and ZZ
         DZZ_IF2: IF ( ANY(ABS(DZZ) > DZZ_CLIP) ) THEN
            IF (ABS(CUT_CELL(ICC)%Q(JCC)) > TWO_EPSILON_EB) Q_EXISTS = .TRUE.
            ! Divergence term
            CALL GET_SPECIFIC_HEAT(ZZ_GET,CP,CUT_CELL(ICC)%TMP(JCC))
            CALL GET_SPECIFIC_GAS_CONSTANT(ZZ_GET,CUT_CELL(ICC)%RSUM(JCC))
            DO N=1,N_TRACKED_SPECIES
               SM => SPECIES_MIXTURE(N)
               CALL GET_SENSIBLE_ENTHALPY_Z(N,CUT_CELL(ICC)%TMP(JCC),H_S_N)
               CUT_CELL(ICC)%D_SOURCE(JCC) = CUT_CELL(ICC)%D_SOURCE(JCC) + &
               ( SM%RCON/CUT_CELL(ICC)%RSUM(JCC) - H_S_N/(CP*CUT_CELL(ICC)%TMP(JCC)) )*DZZ(N)/DT
               CUT_CELL(ICC)%M_DOT_PPP(N,JCC) = CUT_CELL(ICC)%M_DOT_PPP(N,JCC) + &
               CUT_CELL(ICC)%RHO(JCC)*DZZ(N)/DT
            ENDDO
         ENDIF DZZ_IF2
      ENDDO JCC_LOOP
   ENDDO ICC_LOOP

   ! This volume refactoring is needed for RADIATION_FVM (CHI_R, Q) and plotting slices:
   DO ICC=1,MESHES(NM)%N_CUTCELL_MESH
      I     = CUT_CELL(ICC)%IJK(IAXIS)
      J     = CUT_CELL(ICC)%IJK(JAXIS)
      K     = CUT_CELL(ICC)%IJK(KAXIS)

      VCELL = DX(I)*DY(J)*DZ(K)

      IF (CELL(CELL_INDEX(I,J,K))%SOLID) CYCLE ! Cycle in case Cartesian cell inside OBSTS.

      NCELL = CUT_CELL(ICC)%NCELL
      DO JCC=1,NCELL
         Q(I,J,K) = Q(I,J,K)+CUT_CELL(ICC)%Q(JCC)*CUT_CELL(ICC)%VOLUME(JCC)
         CHI_R(I,J,K) = CHI_R(I,J,K) + CUT_CELL(ICC)%CHI_R(JCC)*CUT_CELL(ICC)%Q(JCC)*CUT_CELL(ICC)%VOLUME(JCC)
      ENDDO
      IF(ABS(Q(I,J,K)) > TWO_EPSILON_EB) THEN
         CHI_R(I,J,K) = CHI_R(I,J,K)/Q(I,J,K)
      ELSE
         CHI_R(I,J,K) = 0._EB
         DO JCC=1,NCELL
            CHI_R(I,J,K) = CHI_R(I,J,K) + CUT_CELL(ICC)%CHI_R(JCC)*CUT_CELL(ICC)%VOLUME(JCC)
         ENDDO
         CHI_R(I,J,K) = CHI_R(I,J,K)/VCELL
      ENDIF
      Q(I,J,K) = Q(I,J,K)/VCELL
   ENDDO
ENDIF CC_IBM_IF

CONTAINS


SUBROUTINE CHECK_REACTION

! Check whether any reactions are possible.

LOGICAL :: REACTANTS_PRESENT

DO_REACTION = .FALSE.
REACTION_LOOP: DO NR=1,N_REACTIONS
   RN=>REACTION(NR)
   REACTANTS_PRESENT = .TRUE.
   DO NS=1,RN%N_SMIX_R
      IF (ZZ_GET(RN%REACTANT_INDEX(NS)) < ZZ_MIN_GLOBAL ) THEN
         REACTANTS_PRESENT = .FALSE.
         EXIT
      ENDIF
   ENDDO
   DO_REACTION = REACTANTS_PRESENT
   IF (DO_REACTION) EXIT REACTION_LOOP
ENDDO REACTION_LOOP

END SUBROUTINE CHECK_REACTION

END SUBROUTINE COMBUSTION_GENERAL


SUBROUTINE COMBUSTION_MODEL(T,DT,ZZ_GET,Q_OUT,MIX_TIME_OUT,CHI_R_OUT,CHEM_SUBIT_OUT,REAC_SOURCE_TERM_OUT,Q_REAC_OUT,&
                            TMP_IN,RHO_IN,PRES_IN,MU_IN,DELTA,CELL_VOLUME,IIC,JJC,KKC)
USE MATH_FUNCTIONS, ONLY: EVALUATE_RAMP
USE PHYSICAL_FUNCTIONS, ONLY: GET_REALIZABLE_MF
USE COMP_FUNCTIONS, ONLY: SHUTDOWN
USE DVODECONS, ONLY: ODE_MIN_ATOL
INTEGER, INTENT(IN), OPTIONAL :: IIC,JJC,KKC
REAL(EB), INTENT(IN) :: T,DT,RHO_IN,PRES_IN,MU_IN,DELTA,CELL_VOLUME
REAL(EB), INTENT(OUT) :: Q_OUT,MIX_TIME_OUT,CHI_R_OUT,REAC_SOURCE_TERM_OUT(N_TRACKED_SPECIES),Q_REAC_OUT(N_REACTIONS)
INTEGER, INTENT(OUT) :: CHEM_SUBIT_OUT
REAL(EB), INTENT(INOUT) :: ZZ_GET(1:N_TRACKED_SPECIES)
REAL(EB) :: A1(1:N_TRACKED_SPECIES),A2(1:N_TRACKED_SPECIES),A4(1:N_TRACKED_SPECIES),ZETA,ZETA_0,&
            DT_SUB,DT_SUB_NEW,DT_ITER,ZZ_STORE(1:N_TRACKED_SPECIES,1:4),TV(1:3,1:N_TRACKED_SPECIES),CELL_MASS,&
            ZZ_0(1:N_TRACKED_SPECIES),ZZ_DIFF(1:3,1:N_TRACKED_SPECIES),ZZ_MIXED(1:N_TRACKED_SPECIES),&
            ZZ_MIXED_NEW(1:N_TRACKED_SPECIES),TAU_D,TAU_G,TAU_U,TAU_MIX,DT_SUB_MIN,RHO_HAT,&
            Q_REAC_SUB(1:N_REACTIONS),Q_REAC_1(1:N_REACTIONS),Q_REAC_2(1:N_REACTIONS),Q_REAC_4(1:N_REACTIONS),&
            Q_REAC_SUM(1:N_REACTIONS),Q_SUM_CHI_R,CHI_R_SUM,TIME_RAMP_FACTOR,&
            TOTAL_MIXED_MASS_1,TOTAL_MIXED_MASS_2,TOTAL_MIXED_MASS_4,TOTAL_MIXED_MASS,&
            ZETA_1,ZETA_2,ZETA_4,D_F,TMP_IN,C_U,DT_SUB_OLD,TNOW2,ERR_EST(N_TRACKED_SPECIES),ERR_TOL(N_TRACKED_SPECIES),ERR_TINY,&
            ZZ_TEMP(1:N_TRACKED_SPECIES)
INTEGER :: NR,NS,ITER,TVI,RICH_ITER,TIME_ITER,RICH_ITER_MAX
INTEGER, PARAMETER :: TV_ITER_MIN=5
LOGICAL :: TV_FLUCT(1:N_TRACKED_SPECIES),EXTINCT,NO_REACTIONS
DOUBLE PRECISION :: T1,T2
TYPE(REACTION_TYPE), POINTER :: RN=>NULL() !,R1=>NULL()

ZZ_0 = ZZ_GET
EXTINCT = .FALSE.
NO_REACTIONS = .FALSE.

! Determine the mixing time for this cell


IF (FIXED_MIX_TIME>0._EB) THEN
   MIX_TIME_OUT=FIXED_MIX_TIME
ELSE
   D_F=0._EB
   DO NR =1,N_REACTIONS
      RN => REACTION(NR)
      D_F = MAX(D_F,D_Z(MIN(I_MAX_TEMP-1,NINT(TMP_IN)),RN%FUEL_SMIX_INDEX))
   ENDDO
   TAU_D = DELTA**2/MAX(D_F,TWO_EPSILON_EB)                            ! FDS Tech Guide (5.14)
   SELECT CASE(SIM_MODE)
      CASE DEFAULT
         C_U = 0.4_EB*C_DEARDORFF*SQRT(1.5_EB)
         TAU_U = C_U*RHO_IN*DELTA**2/MAX(MU_IN,TWO_EPSILON_EB)         ! FDS Tech Guide (5.15)
         TAU_G = SQRT(2._EB*DELTA/(GRAV+1.E-10_EB))                    ! FDS Tech Guide (5.16)
         MIX_TIME_OUT= MAX(TAU_CHEM,MIN(TAU_D,TAU_U,TAU_G,TAU_FLAME))  ! FDS Tech Guide (5.13)
      CASE (DNS_MODE)
         MIX_TIME_OUT= MAX(TAU_CHEM,TAU_D)
   END SELECT
ENDIF

ZETA_0 = INITIAL_UNMIXED_FRACTION
CELL_MASS = RHO_IN*CELL_VOLUME

DT_SUB_MIN = DT/REAL(MAX_CHEMISTRY_SUBSTEPS,EB)

ZZ_STORE(:,:) = 0._EB
Q_OUT = 0._EB
ITER= 0
DT_ITER = 0._EB
CHI_R_OUT = 0._EB
CHEM_SUBIT_OUT = 0
REAC_SOURCE_TERM_OUT(:) = 0._EB
Q_REAC_OUT(:) = 0._EB
Q_REAC_SUM(:) = 0._EB
IF (N_FIXED_CHEMISTRY_SUBSTEPS>0) THEN
   DT_SUB = DT/REAL(N_FIXED_CHEMISTRY_SUBSTEPS,EB)
   DT_SUB_NEW = DT_SUB
   RICH_ITER_MAX = 1
ELSE
   DT_SUB = DT
   DT_SUB_NEW = DT
   RICH_ITER_MAX = 5
ENDIF
ZZ_MIXED = ZZ_GET
A1 = ZZ_GET
A2 = ZZ_GET
A4 = ZZ_GET

ZETA = ZETA_0
RHO_HAT = RHO_IN
TAU_MIX = MIX_TIME_OUT

ERR_TINY = TINY_EB / ODE_MIN_ATOL

IF (ALLOCATED(DZ_F0)) THEN
   DZ_F0 = -1._EB
   MOLPCM3 = - 1._EB
ENDIF

TNOW2 = CURRENT_TIME()
INTEGRATION_LOOP: DO TIME_ITER = 1,MAX_CHEMISTRY_SUBSTEPS

   IF (SUPPRESSION) THEN
      DO NR=1,N_REACTIONS
         RN=>REACTION(NR)
         IF (ZZ_0(RN%FUEL_SMIX_INDEX)>TWO_EPSILON_EB .AND. ZZ_0(RN%AIR_SMIX_INDEX)>TWO_EPSILON_EB) THEN
            CALL CHECK_AUTO_IGNITION(EXTINCT,TMP_IN,RN%AUTO_IGNITION_TEMPERATURE,IIC,JJC,KKC,NR)
            IF (.NOT.EXTINCT) EXIT
         ENDIF
      ENDDO
   ENDIF

   IF (EXTINCT) EXIT INTEGRATION_LOOP

   INTEGRATOR_SELECT: SELECT CASE (COMBUSTION_ODE_SOLVER)

      CASE (EXPLICIT_EULER) ! Simple chemistry

         ! May be used with N_FIXED_CHEMISTRY_SUBSTEPS, but default mode is DT_SUB=DT for fast chemistry

         CALL FIRE_FORWARD_EULER(ZZ_MIXED_NEW,ZZ_MIXED,ZZ_0,ZETA,ZETA_0,DT_SUB,TMP_IN,RHO_HAT,&
                                 CELL_MASS,TAU_MIX,Q_REAC_SUB,TOTAL_MIXED_MASS,NO_REACTIONS)
         ZETA_0 = ZETA
         ZZ_MIXED = ZZ_MIXED_NEW

      CASE (RK2_RICHARDSON) ! Finite-rate (or mixed finite-rate/fast) chemistry

         ! May be used with N_FIXED_CHEMISTRY_SUBSTEPS, but default mode is to use error estimator and variable DT_SUB

         RICH_EX_LOOP: DO RICH_ITER = 1,RICH_ITER_MAX

            DT_SUB = MIN(DT_SUB_NEW,DT-DT_ITER)
            ! FDS Tech Guide (E.3), (E.4), (E.5)
            CALL FIRE_RK2(A1,ZZ_MIXED,ZZ_0,ZETA_1,ZETA_0,DT_SUB,1,TMP_IN,RHO_HAT,CELL_MASS,TAU_MIX,&
                        Q_REAC_1,TOTAL_MIXED_MASS_1,NO_REACTIONS)
            IF (NO_REACTIONS) EXIT RICH_EX_LOOP
            CALL FIRE_RK2(A2,ZZ_MIXED,ZZ_0,ZETA_2,ZETA_0,DT_SUB,2,TMP_IN,RHO_HAT,CELL_MASS,TAU_MIX,&
                        Q_REAC_2,TOTAL_MIXED_MASS_2,NO_REACTIONS)
            CALL FIRE_RK2(A4,ZZ_MIXED,ZZ_0,ZETA_4,ZETA_0,DT_SUB,4,TMP_IN,RHO_HAT,CELL_MASS,TAU_MIX,&
                        Q_REAC_4,TOTAL_MIXED_MASS_4,NO_REACTIONS)
            ! Species Error Analysis
            ERR_EST = ABS((4._EB*A4-5._EB*A2+A1))/45._EB ! FDS Tech Guide (E.8)
            ZZ_TEMP = (4._EB*A4-A2)*ONTH ! FDS Tech Guide (E.7)
            DO NS = 1,N_TRACKED_SPECIES
               ERR_TOL(NS) = MAX(0.1_EB*ZZ_MIN_GLOBAL,SPECIES_MIXTURE(NS)%ODE_REL_ERROR*ZZ_TEMP(NS),ODE_MIN_ATOL)
            ENDDO

            IF (N_FIXED_CHEMISTRY_SUBSTEPS<0) THEN
               DT_SUB_OLD = DT_SUB_NEW
               DT_SUB_NEW = MIN(MAX(DT_SUB*MINVAL(ERR_TOL/(ERR_EST+ERR_TINY))**(0.25_EB),DT_SUB_MIN),DT-DT_ITER) ! (E.9)
               IF (ALL(ERR_EST<=ERR_TOL) .OR. ABS(DT_SUB_OLD/DT_SUB_NEW-1._EB) <= 0.1_EB) EXIT RICH_EX_LOOP
            ENDIF

         ENDDO RICH_EX_LOOP

         IF (NO_REACTIONS) THEN
            ZZ_MIXED = A1
            Q_REAC_SUB = 0._EB
            ZETA = ZETA_1
         ELSE
            IF (ANY(ZZ_TEMP < -TWO_EPSILON_EB))THEN
               ZZ_TEMP=A4
               ZZ_MIXED   = ZZ_TEMP
               Q_REAC_SUB = Q_REAC_4
               ZETA       = ZETA_4
            ELSE
               ZZ_MIXED   = ZZ_TEMP
               Q_REAC_SUB = (4._EB*Q_REAC_4-Q_REAC_2)*ONTH
               ZETA       = (4._EB*ZETA_4-ZETA_2)*ONTH
            ENDIF
         ENDIF
         ZETA_0     = ZETA
      CASE (CVODE_SOLVER)
         T1 = T
         T2 = T + DT
         DO NS =1,N_TRACKED_SPECIES
            ATOL(NS) = DBLE(SPECIES_MIXTURE(NS)%ODE_ABS_ERROR)
         ENDDO
         CALL  CVODE(ZZ_MIXED,TMP_IN,PRES_IN, T1,T2, GLOBAL_ODE_REL_ERROR, ATOL)
         Q_REAC_SUB = 0._EB
   END SELECT INTEGRATOR_SELECT

   CALL GET_REALIZABLE_MF(ZZ_MIXED)
   ZZ_GET = ZETA*ZZ_0 + (1._EB-ZETA)*ZZ_MIXED ! FDS Tech Guide (5.19)
   IF (NO_REACTIONS) DT_ITER = DT
   DT_ITER = DT_ITER + DT_SUB
   ITER = ITER + 1
   IF (OUTPUT_CHEM_IT) CHEM_SUBIT_OUT = ITER

   Q_REAC_SUM = Q_REAC_SUM + Q_REAC_SUB

   ! Total Variation (TV) scheme (accelerates integration for finite-rate equilibrium calculations)
   ! See FDS Tech Guide Appendix E

   IF (COMBUSTION_ODE_SOLVER==RK2_RICHARDSON .AND. N_REACTIONS>1) THEN
      DO NS = 1,N_TRACKED_SPECIES
         DO TVI = 1,3
            ZZ_STORE(NS,TVI)=ZZ_STORE(NS,TVI+1)
         ENDDO
         ZZ_STORE(NS,4) = ZZ_GET(NS)
      ENDDO
      TV_FLUCT(:) = .FALSE.
      IF (ITER >= TV_ITER_MIN) THEN
         SPECIES_LOOP_TV: DO NS = 1,N_TRACKED_SPECIES
            DO TVI = 1,3
               TV(TVI,NS) = ABS(ZZ_STORE(NS,TVI+1)-ZZ_STORE(NS,TVI))
               ZZ_DIFF(TVI,NS) = ZZ_STORE(NS,TVI+1)-ZZ_STORE(NS,TVI)
            ENDDO
            IF (SUM(TV(:,NS)) < ERR_TOL(NS) .OR. SUM(TV(:,NS)) >= ABS(2.9_EB*SUM(ZZ_DIFF(:,NS)))) THEN ! FDS Tech Guide (E.10)
               TV_FLUCT(NS) = .TRUE.
            ENDIF
            IF (ALL(TV_FLUCT)) EXIT INTEGRATION_LOOP
         ENDDO SPECIES_LOOP_TV
      ENDIF
   ENDIF
   IF ( DT_ITER > (DT-TWO_EPSILON_EB) ) EXIT INTEGRATION_LOOP

ENDDO INTEGRATION_LOOP
T_USED(16) = T_USED(16) + CURRENT_TIME() - TNOW2
! Compute heat release rate

Q_OUT = -RHO_IN*SUM(SPECIES_MIXTURE%H_F*(ZZ_GET-ZZ_0))/DT ! FDS Tech Guide (5.47)

! Extinction model

IF (SUPPRESSION .AND. .NOT.EXTINCT) THEN
   SELECT CASE(EXTINCT_MOD)
      CASE(EXTINCTION_1); CALL EXTINCT_1(EXTINCT,ZZ_0,TMP_IN)
      CASE(EXTINCTION_2); CALL EXTINCT_2(EXTINCT,ZZ_0,ZZ_MIXED,TMP_IN)
   END SELECT
ENDIF

IF (EXTINCT) THEN
   ZZ_GET = ZZ_0
   ZZ_STORE(:,:) = 0._EB
   Q_OUT = 0._EB
   CHI_R_OUT = 0._EB
   CHEM_SUBIT_OUT = 0
   REAC_SOURCE_TERM_OUT(:) = 0._EB
   Q_REAC_OUT(:) = 0._EB
   Q_REAC_SUM(:) = 0._EB
ENDIF

! Reaction rate-weighted radiative fraction

IF (ANY(Q_REAC_SUM>TWO_EPSILON_EB)) THEN
   Q_SUM_CHI_R = 0._EB
   CHI_R_SUM=0._EB
   DO NR=1,N_REACTIONS
      RN=>REACTION(NR)
      IF (Q_REAC_SUM(NR) > TWO_EPSILON_EB) THEN
         TIME_RAMP_FACTOR = EVALUATE_RAMP(T,RN%RAMP_CHI_R_INDEX)
         CHI_R_SUM = CHI_R_SUM + Q_REAC_SUM(NR)*RN%CHI_R*TIME_RAMP_FACTOR
         Q_SUM_CHI_R = Q_SUM_CHI_R + Q_REAC_SUM(NR)
      ENDIF
   ENDDO
   CHI_R_OUT = CHI_R_SUM/Q_SUM_CHI_R
ELSE
   CHI_R_OUT = REACTION(1)%CHI_R*EVALUATE_RAMP(T,REACTION(1)%RAMP_CHI_R_INDEX)
ENDIF
CHI_R_OUT = MAX(CHI_R_MIN,MIN(CHI_R_MAX,CHI_R_OUT))

! Store special diagnostic quantities

IF (REAC_SOURCE_CHECK) THEN
   REAC_SOURCE_TERM_OUT = RHO_IN*(ZZ_GET-ZZ_0)/DT
   Q_REAC_OUT = Q_REAC_SUM/CELL_VOLUME/DT
ENDIF

END SUBROUTINE COMBUSTION_MODEL

!> \call cvode_interface after converting mass fraction to molar concentration.
!> \during return revert back the molar concentration to mass fraction. 
!> \param ZZ species mass fraction array
!> \param TMP_IN is the temperature
!> \param PR_IN is the pressure
!> \param TCUR is the start time in seconds
!> \param TEND is the end time in seconds
!> \param GLOBAL_ODE_REL_ERROR is the relative error for all the species (REAL_EB)
!> \param ATOL is the absolute error tolerance array for the species (REAL_EB)

SUBROUTINE CVODE(ZZ, TMP_IN, PRES_IN,  TCUR,TEND, GLOBAL_ODE_REL_ERROR, ATOL)
USE PHYSICAL_FUNCTIONS, ONLY : GET_ENTHALPY, GET_SENSIBLE_ENTHALPY, GET_MOLECULAR_WEIGHT, GET_TEMPERATURE

REAL(EB), INTENT(INOUT) :: ZZ(N_TRACKED_SPECIES)
REAL(EB), INTENT(IN) :: ATOL(N_TRACKED_SPECIES)
REAL(EB), INTENT(IN) :: TMP_IN, PRES_IN, TCUR, TEND, GLOBAL_ODE_REL_ERROR

REAL(EB) :: CC(N_TRACKED_SPECIES)
REAL(EB) :: MW, RHO_IN, RHO_OUT, XXX
INTEGER :: NS

CALL GET_MOLECULAR_WEIGHT(ZZ,MW)
RHO_IN = PRES_IN*MW/R0/TMP_IN ! [PR]= Pa, [MW] = g/mol, [R0]= J/K/kmol, [TMP]=K, [RHO]= kg/m3

! Convert to concentration
CC = 0._EB
DO NS =1,N_TRACKED_SPECIES
  CC(NS) = RHO_IN*ZZ(NS)/SPECIES_MIXTURE(NS)%MW  ! [RHO]= kg/m3, [MW] = gm/mol = kg/kmol, [CC] = kmol/m3
ENDDO

#ifdef WITH_SUNDIALS
CALL  CVODE_SERIAL(CC,TMP_IN,PRES_IN, TCUR,TEND, GLOBAL_ODE_REL_ERROR, ATOL)
! Avoid unused build error
XXX = 1._EB
#else
! Avoid unused build error
XXX = MINVAL(ATOL)
XXX = TCUR
XXX = TEND
XXX = GLOBAL_ODE_REL_ERROR
#endif

! Convert back to mass fraction
ZZ(1:N_TRACKED_SPECIES) = CC(1:N_TRACKED_SPECIES)*SPECIES_MIXTURE(1:N_TRACKED_SPECIES)%MW
RHO_OUT = SUM(ZZ)

! Check for negative mass fraction, and rescale to accomodate negative values
WHERE(ZZ<0._EB) ZZ=0._EB
ZZ = ZZ / SUM(ZZ)

END SUBROUTINE CVODE



SUBROUTINE CHECK_AUTO_IGNITION(EXTINCT,TMP_IN,AIT,IIC,JJC,KKC,REAC_INDEX)

! For combustion to proceed the local gas temperature must be greater than AIT unless the cell has been excluded.

USE DEVICE_VARIABLES, ONLY: DEVICE
LOGICAL, INTENT(INOUT) :: EXTINCT
REAL(EB), INTENT(IN) :: TMP_IN,AIT
INTEGER, INTENT(IN) :: IIC,JJC,KKC,REAC_INDEX
INTEGER :: IZ
TYPE(REACTION_TYPE), POINTER :: RN

RN => REACTION(REAC_INDEX)

DO IZ=1,RN%N_AIT_EXCLUSION_ZONES

   IF (RN%AIT_EXCLUSION_ZONE(IZ)%DEVC_INDEX>0) THEN
      IF (.NOT.DEVICE(RN%AIT_EXCLUSION_ZONE(IZ)%DEVC_INDEX)%CURRENT_STATE) CYCLE
   ENDIF

   IF (XC(IIC)>=RN%AIT_EXCLUSION_ZONE(IZ)%X1 .AND. XC(IIC)<=RN%AIT_EXCLUSION_ZONE(IZ)%X2 .AND.  &
       YC(JJC)>=RN%AIT_EXCLUSION_ZONE(IZ)%Y1 .AND. YC(JJC)<=RN%AIT_EXCLUSION_ZONE(IZ)%Y2 .AND.  &
       ZC(KKC)>=RN%AIT_EXCLUSION_ZONE(IZ)%Z1 .AND. ZC(KKC)<=RN%AIT_EXCLUSION_ZONE(IZ)%Z2) RETURN

ENDDO

EXTINCT = .TRUE.

IF (TMP_IN > AIT) EXTINCT = .FALSE.

END SUBROUTINE CHECK_AUTO_IGNITION


!> \brief Determine if the reaction can occur using the less detailed extinction model (FDS Tech Guide, Section 5.3.2)
!> \param EXTINCT Logical parameter indicating if extinction has occurred in the cell
!> \param ZZ_0 Array of lumped species mass fractions in the mixed part of the grid cell at the start of the time step
!> \param TMP_IN Initial temperature of the grid cell

SUBROUTINE EXTINCT_1(EXTINCT,ZZ_0,TMP_IN)

USE PHYSICAL_FUNCTIONS, ONLY: GET_MASS_FRACTION
REAL(EB), INTENT(IN) :: TMP_IN,ZZ_0(1:N_TRACKED_SPECIES)
LOGICAL, INTENT(INOUT) :: EXTINCT
REAL(EB) :: Y_O2,Y_O2_LIM,TMP_FACTOR,CFT
TYPE(REACTION_TYPE), POINTER :: R1

! Use a single critical flame temperature from reaction 1

R1 => REACTION(1)
CFT = R1%CRITICAL_FLAME_TEMPERATURE

! Evaluate extinction criterion using cell oxygen mass fraction based on Tech Guide Fig. 5.2 and Eq. 5.53

CALL GET_MASS_FRACTION(ZZ_0,O2_INDEX,Y_O2)
IF (TMP_IN < FREE_BURN_TEMPERATURE) THEN
   TMP_FACTOR = (CFT-TMP_IN)/(CFT-TMPA)
ELSE
   TMP_FACTOR = 0._EB
ENDIF
Y_O2_LIM = R1%Y_O2_MIN*TMP_FACTOR
IF (Y_O2 < Y_O2_LIM) EXTINCT = .TRUE.

END SUBROUTINE EXTINCT_1


!> \brief Determine if the reaction can occur using the more detailed extinction model (FDS Tech Guide, Section 5.3.3)
!> \param EXTINCT Logical parameter indicating if extinction has occurred in the cell
!> \param ZZ_0 Array of lumped species mass fractions in the mixed part of the grid cell at the start of the time step
!> \param ZZ_IN Array of lumped species mass fractions in the mixed part of the grid cell at the end of the time step
!> \param TMP_IN Initial temperature of the grid cell

SUBROUTINE EXTINCT_2(EXTINCT,ZZ_0,ZZ_IN,TMP_IN)

USE PHYSICAL_FUNCTIONS, ONLY: GET_ENTHALPY
REAL(EB),INTENT(IN) :: TMP_IN,ZZ_IN(1:N_TRACKED_SPECIES),ZZ_0(1:N_TRACKED_SPECIES)
LOGICAL, INTENT(INOUT) :: EXTINCT
REAL(EB) :: ZZ_HAT_0(1:N_TRACKED_SPECIES),ZZ_HAT(1:N_TRACKED_SPECIES),H_0,H_CRIT,PHI_TILDE,CFT
INTEGER :: NS,NR
REAL(EB) :: SUM_ZZ,SUM_CFT
TYPE(REACTION_TYPE), POINTER :: RN,R1

! Get the weighted average of the critical flame temperature (CFT) based on the relative amounts of fuels of the primary reactions

SUM_CFT = 0._EB
SUM_ZZ  = 0._EB
DO NR=1,N_REACTIONS
   RN => REACTION(NR)
   IF (RN%PRIORITY/=1) CYCLE
   SUM_CFT = SUM_CFT + ZZ_0(RN%FUEL_SMIX_INDEX)*RN%CRITICAL_FLAME_TEMPERATURE
   SUM_ZZ  = SUM_ZZ  + ZZ_0(RN%FUEL_SMIX_INDEX)
ENDDO

IF (SUM_ZZ < TWO_EPSILON_EB) THEN
   EXTINCT = .TRUE.
   RETURN
ENDIF

CFT = SUM_CFT/SUM_ZZ

! Compute the modified cell equivalence ratio

R1 => REACTION(1)
PHI_TILDE = (ZZ_0(R1%AIR_SMIX_INDEX) - ZZ_IN(R1%AIR_SMIX_INDEX)) / ZZ_0(R1%AIR_SMIX_INDEX)  ! FDS Tech Guide (5.54)

IF ( PHI_TILDE < TWO_EPSILON_EB ) THEN
   EXTINCT = .TRUE.
   RETURN
ENDIF

! Define the modified pre and post-reaction mixtures (ZZ_HAT_0 and ZZ_HAT) in which excess air and products are excluded.

DO NR=1,N_REACTIONS
   RN => REACTION(NR)
   DO NS=1,N_TRACKED_SPECIES
      IF (NS==RN%FUEL_SMIX_INDEX) THEN
         ZZ_HAT_0(NS) = ZZ_0(NS)
         ZZ_HAT(NS)   = ZZ_IN(NS)
      ELSEIF (NS==RN%AIR_SMIX_INDEX) THEN
         ZZ_HAT_0(NS) = PHI_TILDE * ZZ_0(NS)
         ZZ_HAT(NS)   = 0._EB
      ELSE  ! Products
         ZZ_HAT_0(NS) = PHI_TILDE * ZZ_0(NS)
         ZZ_HAT(NS)   = (PHI_TILDE-1._EB)*ZZ_0(NS) + ZZ_IN(NS)
      ENDIF
   ENDDO
ENDDO

! Normalize the modified pre and post-reaction mixtures

ZZ_HAT_0 = ZZ_HAT_0/SUM(ZZ_HAT_0)
ZZ_HAT   = ZZ_HAT/SUM(ZZ_HAT)

! Determine if enough energy is released to raise the fuel and required "air" temperatures above the critical flame temp.

CALL GET_ENTHALPY(ZZ_HAT_0,H_0,TMP_IN) ! H of reactants participating in reaction (includes chemical enthalpy)
CALL GET_ENTHALPY(ZZ_HAT,H_CRIT,CFT)   ! H of products at the critical flame temperature
IF (H_0 < H_CRIT) EXTINCT = .TRUE. ! FDS Tech Guide (5.55)

END SUBROUTINE EXTINCT_2


SUBROUTINE FIRE_FORWARD_EULER(ZZ_OUT,ZZ_IN,ZZ_0,ZETA_OUT,ZETA_IN,DT_LOC,TMP_IN,RHO_HAT,CELL_MASS,TAU_MIX,&
                              Q_REAC_LOC,TOTAL_MIXED_MASS,NO_REACTIONS)
USE PHYSICAL_FUNCTIONS, ONLY: GET_REALIZABLE_MF,GET_AVERAGE_SPECIFIC_HEAT
REAL(EB), INTENT(IN) :: ZZ_0(1:N_TRACKED_SPECIES),ZZ_IN(1:N_TRACKED_SPECIES),ZETA_IN,DT_LOC,RHO_HAT,CELL_MASS,TAU_MIX
REAL(EB), INTENT(OUT) :: ZZ_OUT(1:N_TRACKED_SPECIES),ZETA_OUT,Q_REAC_LOC(1:N_REACTIONS),TOTAL_MIXED_MASS
REAL(EB), INTENT(INOUT) :: TMP_IN
LOGICAL , INTENT(OUT) :: NO_REACTIONS
REAL(EB) :: ZZ_HAT(1:N_TRACKED_SPECIES),DZZ(1:N_TRACKED_SPECIES),&
            MIXED_MASS(1:N_TRACKED_SPECIES),MIXED_MASS_0(1:N_TRACKED_SPECIES),&
            Q_REAC_OUT(1:N_REACTIONS),TOTAL_MIXED_MASS_0
INTEGER, PARAMETER :: INFINITELY_FAST=1,FINITE_RATE=2
INTEGER :: PTY

! Determine initial state of mixed reactor zone
TOTAL_MIXED_MASS_0  = (1._EB-ZETA_IN)*CELL_MASS
MIXED_MASS_0  = ZZ_IN*TOTAL_MIXED_MASS_0

! Mixing step

ZETA_OUT = MAX(0._EB,ZETA_IN*EXP(-DT_LOC/TAU_MIX)) ! FDS Tech Guide (5.18)
TOTAL_MIXED_MASS = (1._EB-ZETA_OUT)*CELL_MASS      ! FDS Tech Guide (5.23)
MIXED_MASS = MAX(0._EB,MIXED_MASS_0 - (ZETA_OUT - ZETA_IN)*ZZ_0*CELL_MASS) ! FDS Tech Guide (5.26)
ZZ_HAT = MIXED_MASS/MAX(TOTAL_MIXED_MASS,TWO_EPSILON_EB) ! FDS Tech Guide (5.27)

! Enforce realizability on mass fractions

CALL GET_REALIZABLE_MF(ZZ_HAT)

! Do the infinite rate (fast chemistry) reactions either in parallel (PRIORITY=1 for all) or serially (PRIORITY>1 for some)

Q_REAC_LOC(:) = 0._EB
IF (ANY(REACTION%FAST_CHEMISTRY)) THEN
   DO PTY = 1,MAX_PRIORITY
      CALL REACTION_RATE(DZZ,ZZ_HAT,DT_LOC,RHO_HAT,TMP_IN,INFINITELY_FAST,Q_REAC_OUT,NO_REACTIONS,PRIORITY=PTY)
      ZZ_HAT = ZZ_HAT + DZZ
      Q_REAC_LOC = Q_REAC_LOC + Q_REAC_OUT*TOTAL_MIXED_MASS
   ENDDO
ENDIF

! Do all finite rate reactions in parallel

IF (.NOT.ALL(REACTION%FAST_CHEMISTRY)) THEN
   CALL REACTION_RATE(DZZ,ZZ_HAT,DT_LOC,RHO_HAT,TMP_IN,FINITE_RATE,Q_REAC_OUT,NO_REACTIONS)
   ZZ_HAT = ZZ_HAT + DZZ
   Q_REAC_LOC = Q_REAC_LOC + Q_REAC_OUT*TOTAL_MIXED_MASS
ENDIF

! Enforce realizability on mass fractions

CALL GET_REALIZABLE_MF(ZZ_HAT)

ZZ_OUT = ZZ_HAT

END SUBROUTINE FIRE_FORWARD_EULER


SUBROUTINE FIRE_RK2(ZZ_OUT,ZZ_IN,ZZ_0,ZETA_OUT,ZETA_IN,DT_SUB,N_INC,TMP_IN,RHO_HAT,CELL_MASS,TAU_MIX,&
                    Q_REAC_OUT,TOTAL_MIXED_MASS_OUT,NO_REACTIONS)

! This function uses RK2 to integrate ZZ_O from t=0 to t=DT_SUB in increments of DT_LOC=DT_SUB/N_INC

REAL(EB), INTENT(IN) :: ZZ_0(1:N_TRACKED_SPECIES),ZZ_IN(1:N_TRACKED_SPECIES),DT_SUB,ZETA_IN,RHO_HAT,CELL_MASS,&
                        TAU_MIX
REAL(EB), INTENT(OUT) :: ZZ_OUT(1:N_TRACKED_SPECIES),ZETA_OUT,Q_REAC_OUT(1:N_REACTIONS),TOTAL_MIXED_MASS_OUT
INTEGER, INTENT(IN) :: N_INC
LOGICAL, INTENT(OUT) :: NO_REACTIONS
REAL(EB) :: DT_LOC,ZZ_TMP_0(1:N_TRACKED_SPECIES),ZZ_TMP_1(1:N_TRACKED_SPECIES),ZZ_TMP_2(1:N_TRACKED_SPECIES),&
            ZETA_TMP_0,ZETA_TMP_1,ZETA_TMP_2,&
            Q_REAC_1(1:N_REACTIONS),Q_REAC_2(1:N_REACTIONS),TOTAL_MIXED_MASS_0,TOTAL_MIXED_MASS_1,TOTAL_MIXED_MASS_2,TMP_IN
INTEGER :: N

DT_LOC = DT_SUB/REAL(N_INC,EB)
ZZ_TMP_0 = ZZ_IN
ZETA_TMP_0 = ZETA_IN
Q_REAC_OUT(:) = 0._EB
TOTAL_MIXED_MASS_0 = (1._EB-ZETA_TMP_0)*CELL_MASS

DO N=1,N_INC
   CALL FIRE_FORWARD_EULER(ZZ_TMP_1,ZZ_TMP_0,ZZ_0,ZETA_TMP_1,ZETA_TMP_0,DT_LOC,TMP_IN,RHO_HAT,CELL_MASS,TAU_MIX,&
                           Q_REAC_1,TOTAL_MIXED_MASS_1,NO_REACTIONS)

   CALL FIRE_FORWARD_EULER(ZZ_TMP_2,ZZ_TMP_1,ZZ_0,ZETA_TMP_2,ZETA_TMP_1,DT_LOC,TMP_IN,RHO_HAT,CELL_MASS,TAU_MIX,&
                           Q_REAC_2,TOTAL_MIXED_MASS_2,NO_REACTIONS)

   IF (TOTAL_MIXED_MASS_2>TWO_EPSILON_EB) THEN
      ZZ_OUT = 0.5_EB*(ZZ_TMP_0*TOTAL_MIXED_MASS_0 + ZZ_TMP_2*TOTAL_MIXED_MASS_2)
      TOTAL_MIXED_MASS_OUT = SUM(ZZ_OUT)
      ZZ_OUT = ZZ_OUT/TOTAL_MIXED_MASS_OUT
   ELSE
      ZZ_OUT = ZZ_TMP_0
   ENDIF

   ZETA_OUT = MAX(0._EB,1._EB-TOTAL_MIXED_MASS_OUT/CELL_MASS)

   Q_REAC_OUT = Q_REAC_OUT + 0.5_EB*(Q_REAC_1+Q_REAC_2)

   ZZ_TMP_0 = ZZ_OUT
   ZETA_TMP_0 = ZETA_OUT
   TOTAL_MIXED_MASS_0 = TOTAL_MIXED_MASS_OUT
   IF (NO_REACTIONS) RETURN

ENDDO

END SUBROUTINE FIRE_RK2


SUBROUTINE REACTION_RATE(DZZ,ZZ_OLD,DT_SUB,RHO_0,TMP_0,KINETICS,Q_REAC_OUT,NO_REACTIONS,PRIORITY)

USE PHYSICAL_FUNCTIONS, ONLY : GET_MASS_FRACTION_ALL,GET_SPECIFIC_GAS_CONSTANT,GET_MOLECULAR_WEIGHT
REAL(EB), INTENT(OUT) :: DZZ(1:N_TRACKED_SPECIES),Q_REAC_OUT(1:N_REACTIONS)
REAL(EB), INTENT(IN) :: ZZ_OLD(1:N_TRACKED_SPECIES),DT_SUB,RHO_0,TMP_0
LOGICAL, INTENT(OUT) :: NO_REACTIONS
INTEGER, INTENT(IN) :: KINETICS
INTEGER, INTENT(IN), OPTIONAL :: PRIORITY
REAL(EB) :: DZ_F,YY_PRIMITIVE(1:N_SPECIES),MW,DT_TMP(1:N_TRACKED_SPECIES),DT_MIN,DT_LOC,&
            ZZ_TMP(1:N_TRACKED_SPECIES),ZZ_NEW(1:N_TRACKED_SPECIES),Q_REAC_TMP(1:N_REACTIONS),AA,X_Y(1:N_SPECIES),X_Y_SUM,&
            K_INF,K_0,P_RI,FCENT,C_I
INTEGER :: I,NS,OUTER_IT
LOGICAL :: REACTANTS_PRESENT
INTEGER, PARAMETER :: INFINITELY_FAST=1,FINITE_RATE=2
TYPE(REACTION_TYPE), POINTER :: RN=>NULL()

ZZ_NEW = ZZ_OLD
Q_REAC_OUT = 0._EB
Q_REAC_TMP = 0._EB
RRTMP0 = 1._EB/(R0*TMP_0)

KINETICS_SELECT: SELECT CASE(KINETICS)

   CASE(INFINITELY_FAST)

      NO_REACTIONS = .FALSE.
      FAST_REAC_LOOP: DO OUTER_IT=1,N_REACTIONS
         ZZ_TMP = ZZ_NEW
         DZZ = 0._EB
         REACTANTS_PRESENT = .FALSE.
         REACTION_LOOP_1: DO I=1,N_REACTIONS
            RN => REACTION(I)
            IF (.NOT.RN%FAST_CHEMISTRY .OR. RN%PRIORITY/=PRIORITY) CYCLE REACTION_LOOP_1
            IF (RN%AIR_SMIX_INDEX > -1) THEN
               DZ_F = ZZ_TMP(RN%FUEL_SMIX_INDEX)*ZZ_TMP(RN%AIR_SMIX_INDEX) ! 2nd-order reaction
            ELSE
               DZ_F = ZZ_TMP(RN%FUEL_SMIX_INDEX) ! 1st-order
            ENDIF
            IF (DZ_F > TWO_EPSILON_EB) REACTANTS_PRESENT = .TRUE.
            AA = RN%A_PRIME * RHO_0**RN%RHO_EXPONENT
            DZZ = DZZ + AA * RN%NU_MW_O_MW_F * DZ_F
            Q_REAC_TMP(I) = RN%HEAT_OF_COMBUSTION * AA * DZ_F
         ENDDO REACTION_LOOP_1
         IF (REACTANTS_PRESENT) THEN
            DT_TMP = HUGE_EB
            DO NS = 1,N_TRACKED_SPECIES
               IF (DZZ(NS) < 0._EB) DT_TMP(NS) = -ZZ_TMP(NS)/DZZ(NS)
            ENDDO
            DT_MIN = MINVAL(DT_TMP)
            ZZ_NEW = ZZ_TMP + DZZ*DT_MIN
            Q_REAC_OUT = Q_REAC_OUT + Q_REAC_TMP*DT_MIN
         ELSE
            EXIT FAST_REAC_LOOP
         ENDIF
      ENDDO FAST_REAC_LOOP
      DZZ = ZZ_NEW - ZZ_OLD

   CASE(FINITE_RATE)

      DT_LOC = DT_SUB
      NO_REACTIONS = .TRUE.
      SLOW_REAC_LOOP: DO OUTER_IT=1,N_REACTIONS
         ZZ_TMP = ZZ_NEW
         CALL GET_MASS_FRACTION_ALL(ZZ_TMP,YY_PRIMITIVE)
         DZZ = 0._EB
         REACTANTS_PRESENT = .FALSE.
         REACTION_LOOP_2: DO I=1,N_REACTIONS
            RN => REACTION(I)
            IF (RN%FAST_CHEMISTRY) CYCLE REACTION_LOOP_2
            ! Check for consumed species
            DO NS=1,RN%N_SMIX_FR
               IF (RN%NU_MW_O_MW_F_FR(NS) < 0._EB .AND. ZZ_TMP(RN%NU_INDEX(NS)) < ZZ_MIN_GLOBAL) CYCLE REACTION_LOOP_2
            ENDDO
            ! Check for species with concentration exponents
            DO NS=1,RN%N_SPEC
               IF(YY_PRIMITIVE(RN%N_S_INDEX(NS)) < ZZ_MIN_GLOBAL) CYCLE REACTION_LOOP_2
            ENDDO
            NO_REACTIONS = .FALSE.
            ! dZ/dt, FDS Tech Guide, Eq. (5.38)

            ! T doesn't change, MOLPCM3 should not have a large absolute change, and third collision species with non-unity 
            ! efficiencies are generally species with high expected mass fractions which should not have large absolute changes.
            ! We can make a constant term for each reaction to hold A T^N_T e^-(E/RT) * Gibbs * Third body
            IF (DZ_F0(I) < 0._EB) THEN
               K_INF = RN%A_PRIME*RHO_0**RN%RHO_EXPONENT*TMP_0**RN%N_T*EXP(-RN%E*RRTMP0)
               DZ_F0(I) = K_INF
               IF (RN%THIRD_BODY) THEN
                  IF (RN%N_THIRD <=0) THEN
                     IF (MOLPCM3 < 0._EB) THEN
                        CALL GET_MOLECULAR_WEIGHT(ZZ_TMP,MW)
                        MOLPCM3 = RHO_0/MW*0.001_EB ! mol/cm^3
                     ENDIF
                     DZ_F0(I) = DZ_F0(I)*MOLPCM3
                  ENDIF
                  IF (RN%REACTYPE==FALLOFF_LINDEMANN_TYPE .OR. RN%REACTYPE==FALLOFF_TROE_TYPE) THEN
                     K_0 = RN%A_LOW_PR*TMP_0**(RN%N_T_LOW_PR)*EXP(-RN%E_LOW_PR*RRTMP0)
                     P_RI = K_0/K_INF
                     FCENT = CALC_FCENT(TMP_0,P_RI,I)
                     C_I = P_RI/(1._EB+P_RI)*FCENT
                     DZ_F0(I) = DZ_F0(I)*C_I                     
                  ENDIF
               ENDIF
               IF (RN%REVERSE) THEN ! compute equilibrium constant
                  IF (MOLPCM3 < 0._EB) THEN
                     CALL GET_MOLECULAR_WEIGHT(ZZ_TMP,MW)
                     MOLPCM3 = RHO_0/MW*0.001_EB ! mol/cm^3
                  ENDIF
                  DZ_F0(I) = DZ_F0(I)*EXP(RN%DELTA_G(MIN(I_MAX_TEMP,NINT(TMP_0)))/TMP_0)*MOLPCM3**RN%C0_EXP
               ENDIF
            ENDIF
            DZ_F = DZ_F0(I)
            IF (RN%THIRD_BODY) THEN
               IF (RN%N_THIRD > 0) THEN
                  X_Y_SUM = 0._EB
                  DO NS=1,N_SPECIES
                     X_Y(NS) = YY_PRIMITIVE(NS)/SPECIES(NS)%MW
                     X_Y_SUM = X_Y_SUM + X_Y(NS)
                     X_Y(NS) = X_Y(NS)*RN%THIRD_EFF(NS)
                  ENDDO
                  DZ_F = DZ_F * MOLPCM3 * SUM(X_Y)/X_Y_SUM
               ENDIF
            ENDIF
            DO NS=1,RN%N_SPEC
               IF (RN%N_S_FLAG(NS)) THEN
                  DZ_F = YY_PRIMITIVE(RN%N_S_INDEX(NS))**RN%N_S_INT(NS)*DZ_F
               ELSE
                  DZ_F = DZ_F*YY_PRIMITIVE(RN%N_S_INDEX(NS))**RN%N_S(NS)
               ENDIF
            ENDDO
            IF (DZ_F > TWO_EPSILON_EB) REACTANTS_PRESENT = .TRUE.
            Q_REAC_TMP(I) = RN%HEAT_OF_COMBUSTION * DZ_F * DT_LOC ! Note: here DZ_F=dZ/dt, hence need DT_LOC
            DZ_F = DZ_F*DT_LOC
            DO NS=1,RN%N_SMIX_FR
               DZZ(RN%NU_INDEX(NS)) = DZZ(RN%NU_INDEX(NS)) + RN%NU_MW_O_MW_F_FR(NS)*DZ_F
            ENDDO
         ENDDO REACTION_LOOP_2
         IF (NO_REACTIONS) RETURN
         IF (REACTANTS_PRESENT) THEN
            DT_TMP = HUGE_EB
            DO NS = 1,N_TRACKED_SPECIES
               IF (DZZ(NS) < 0._EB) DT_TMP(NS) = -ZZ_TMP(NS)/DZZ(NS)
            ENDDO
            ! Think of DT_MIN as the fraction of DT_LOC we can take and remain bounded.
            DT_MIN = MIN(1._EB,MINVAL(DT_TMP))
            DT_LOC = DT_LOC*(1._EB-DT_MIN)
            ZZ_NEW = ZZ_TMP + DZZ*DT_MIN
            Q_REAC_OUT = Q_REAC_OUT + Q_REAC_TMP*DT_MIN
            IF (DT_LOC<TWO_EPSILON_EB) EXIT SLOW_REAC_LOOP
         ELSE
            EXIT SLOW_REAC_LOOP
         ENDIF
      ENDDO SLOW_REAC_LOOP
      DZZ = ZZ_NEW - ZZ_OLD

END SELECT KINETICS_SELECT

END SUBROUTINE REACTION_RATE


!> \brief Compute adiabatic flame tmperature for reaction mixture
!>
!> \param TMP_FLAME  Adiabatic flame temperature in stoichiometric reaction pocket (K)
!> \param PHI_TILDE  Equivalence ratio in stoich reaction pocket
!> \param ZZ_HAT     Post flame composition stoich reaction pocket
!> \param ZZ_0       Pre flame cell mixture composition
!> \param ZZ_IN      Post flame cell mixture composition
!> \param TMP_IN     Cell temperature (K)
!> \param REAC_INDEX Index of reaction

SUBROUTINE GET_FLAME_TEMPERATURE(TMP_FLAME,PHI_TILDE,ZZ_HAT,ZZ_0,ZZ_IN,TMP_IN,REAC_INDEX)

USE PHYSICAL_FUNCTIONS, ONLY: GET_ENTHALPY
REAL(EB),INTENT(IN) :: TMP_IN,ZZ_0(1:N_TRACKED_SPECIES),ZZ_IN(1:N_TRACKED_SPECIES)
INTEGER, INTENT(IN) :: REAC_INDEX
REAL(EB),INTENT(OUT) :: TMP_FLAME,ZZ_HAT(1:N_TRACKED_SPECIES),PHI_TILDE
REAL(EB) :: H_0,TMP_1,TMP_2,H_1,H_2,H_REL_ERROR,ZZ_HAT_0(1:N_TRACKED_SPECIES)
INTEGER :: NS,ITER
REAL(EB), PARAMETER :: ERROR_TOL=0.01_EB, TMPMAX_FLAME=5000._EB
INTEGER, PARAMETER :: MAXIT=10
TYPE(REACTION_TYPE), POINTER :: RN=>NULL()

TMP_FLAME = TMP_IN
ZZ_HAT = ZZ_IN
PHI_TILDE = 0._EB

IF (.NOT.REACTION(REAC_INDEX)%FAST_CHEMISTRY) RETURN
RN => REACTION(REAC_INDEX)

! This construct for the equivalence ratio does not rely on a single reaction

IF (ZZ_IN(RN%AIR_SMIX_INDEX)>TWO_EPSILON_EB) THEN
   ! Excess AIR
   PHI_TILDE = (ZZ_0(RN%AIR_SMIX_INDEX) - ZZ_IN(RN%AIR_SMIX_INDEX)) / MAX( ZZ_0(RN%AIR_SMIX_INDEX), TWO_EPSILON_EB )
ELSE
   ! Excess FUEL
   PHI_TILDE = ZZ_0(RN%FUEL_SMIX_INDEX) / MAX( (ZZ_0(RN%FUEL_SMIX_INDEX) - ZZ_IN(RN%FUEL_SMIX_INDEX)), TWO_EPSILON_EB )
ENDIF

IF ( PHI_TILDE < TWO_EPSILON_EB ) THEN
   PHI_TILDE = 0._EB
   RETURN
ELSEIF ( (1._EB/PHI_TILDE) < TWO_EPSILON_EB ) THEN
   PHI_TILDE = 0._EB
   RETURN
ENDIF

! Define the stoichiometric pre and post mixtures (ZZ_HAT_0 and ZZ_HAT).

IF (PHI_TILDE<1._EB) THEN
   ! Excess AIR
   DO NS=1,N_TRACKED_SPECIES
      IF (NS==RN%FUEL_SMIX_INDEX) THEN
         ZZ_HAT_0(NS) = ZZ_0(NS)
         ZZ_HAT(NS)   = 0._EB
      ELSEIF (NS==RN%AIR_SMIX_INDEX) THEN
         ZZ_HAT_0(NS) = PHI_TILDE * ZZ_0(NS)
         ZZ_HAT(NS)   = 0._EB
      ELSE  ! Products
         ZZ_HAT_0(NS) = PHI_TILDE * ZZ_0(NS)
         ZZ_HAT(NS)   = ZZ_IN(NS) - (1._EB - PHI_TILDE) * ZZ_0(NS)
      ENDIF
   ENDDO
ELSE
   ! Excess FUEL
   DO NS=1,N_TRACKED_SPECIES
      IF (NS==RN%FUEL_SMIX_INDEX) THEN
         ZZ_HAT_0(NS) = 1._EB/PHI_TILDE * ZZ_0(NS)
         ZZ_HAT(NS)   = 0._EB
      ELSEIF (NS==RN%AIR_SMIX_INDEX) THEN
         ZZ_HAT_0(NS) = ZZ_0(NS)
         ZZ_HAT(NS)   = 0._EB
      ELSE  ! Products
         ZZ_HAT_0(NS) = 1._EB/PHI_TILDE * ZZ_0(NS)
         ZZ_HAT(NS)   = ZZ_IN(NS) - (1._EB - 1._EB/PHI_TILDE) * ZZ_0(NS)
      ENDIF
   ENDDO
ENDIF

! Normalize the modified pre and post mixtures

IF (SUM(ZZ_HAT_0)<TWO_EPSILON_EB) THEN
   ZZ_HAT = ZZ_IN
   PHI_TILDE = 0._EB
   RETURN
ELSE
   ZZ_HAT_0 = ZZ_HAT_0/SUM(ZZ_HAT_0)
ENDIF
IF (SUM(ZZ_HAT)<TWO_EPSILON_EB) THEN
   ZZ_HAT = ZZ_IN
   PHI_TILDE = 0._EB
   RETURN
ELSE
   ZZ_HAT = ZZ_HAT/SUM(ZZ_HAT)
ENDIF

! Iteratively guess (Newton method) flame temp until products enthalpy matches reactant enthalpy.

CALL GET_ENTHALPY(ZZ_HAT_0,H_0,TMP_IN) ! H of reactants participating in reaction (includes chemical enthalpy)
TMP_1 = 2000._EB ! converges faster with better initial guess (only takes 2 or 3 iterations)
TMP_2 = 2100._EB
TMP_FLAME = TMP_2
ITER = 0
H_REL_ERROR = 1._EB
DO WHILE (ABS(H_REL_ERROR)>ERROR_TOL)
   ITER = ITER + 1
   IF (ITER>MAXIT) EXIT

   CALL GET_ENTHALPY(ZZ_HAT,H_1,TMP_1)
   CALL GET_ENTHALPY(ZZ_HAT,H_2,TMP_2)

   IF (ABS(H_2-H_1)>TWO_EPSILON_EB) THEN
      TMP_FLAME = TMP_1 + (TMP_2-TMP_1)/(H_2-H_1) * (H_0-H_1)
      TMP_FLAME = MAX(TMPMIN,MIN(TMPMAX_FLAME,TMP_FLAME))
   ENDIF
   H_REL_ERROR = (H_2-H_0)/H_0 ! converged when enthalpy relative error less than 1%
   TMP_1 = TMP_2
   TMP_2 = TMP_FLAME
ENDDO

END SUBROUTINE GET_FLAME_TEMPERATURE


SUBROUTINE COMBUSTION_BC(NM)

! Specify ghost cell values of the HRRPUV, Q

USE COMP_FUNCTIONS, ONLY: CURRENT_TIME
INTEGER, INTENT(IN) :: NM
REAL(EB) :: Q_OTHER,TNOW
INTEGER :: IW,IIO,JJO,KKO,NOM,N_INT_CELLS
TYPE(WALL_TYPE),POINTER :: WC
TYPE(BOUNDARY_COORD_TYPE),POINTER :: BC
TYPE(EXTERNAL_WALL_TYPE),POINTER :: EWC

TNOW=CURRENT_TIME()

CALL POINT_TO_MESH(NM)

WALL_LOOP: DO IW=1,N_EXTERNAL_WALL_CELLS
   WC =>WALL(IW)
   EWC=>EXTERNAL_WALL(IW)
   IF (EWC%NOM==0) CYCLE WALL_LOOP
   BC => BOUNDARY_COORD(WC%BC_INDEX)
   NOM = EWC%NOM
   Q_OTHER   = 0._EB
   DO KKO=EWC%KKO_MIN,EWC%KKO_MAX
      DO JJO=EWC%JJO_MIN,EWC%JJO_MAX
         DO IIO=EWC%IIO_MIN,EWC%IIO_MAX
            Q_OTHER = Q_OTHER + OMESH(NOM)%Q(IIO,JJO,KKO)
         ENDDO
      ENDDO
   ENDDO
   N_INT_CELLS = (EWC%IIO_MAX-EWC%IIO_MIN+1) * (EWC%JJO_MAX-EWC%JJO_MIN+1) * (EWC%KKO_MAX-EWC%KKO_MIN+1)
   Q(BC%II,BC%JJ,BC%KK) = Q_OTHER/REAL(N_INT_CELLS,EB)
ENDDO WALL_LOOP

T_USED(10)=T_USED(10)+CURRENT_TIME()-TNOW
END SUBROUTINE COMBUSTION_BC


SUBROUTINE CONDENSATION_EVAPORATION(DT,NM)
USE MATH_FUNCTIONS, ONLY : INTERPOLATE1D_UNIFORM
USE PHYSICAL_FUNCTIONS, ONLY : GET_SPECIFIC_HEAT, GET_MASS_FRACTION_ALL, GET_VISCOSITY, GET_MOLECULAR_WEIGHT,RELATIVE_HUMIDITY
USE COMPLEX_GEOMETRY, ONLY : CC_CGSC, CC_GASPHASE
INTEGER, INTENT(IN):: NM
REAL(EB), INTENT(IN):: DT
INTEGER:: I,J,K, NS, NS2, Y_INDEX, Z_COND_INDEX, IW, NMAT, ITMP
REAL(EB), PARAMETER :: P_STP = 101325._EB
REAL(EB):: Y_GAS, DHOR, H_V_B, H_V_A, H_V, H_V_N, MW_RATIO, MW_GAS, ZZ_GET(1:N_TRACKED_SPECIES),&
           X_CLOUD, Y_CLOUD, CP, TMP_N, Y_N, Y_1, Y_2, X_GUESS,Y_GUESS, Y_ALL(1:N_SPECIES), P_RATIO, Y_COND, &
           T_BOIL_EFF, RHO_G, TMP_G, TMP_W, Y_NN, D_AIR,H_MASS,N_PART,X_WALL,Y_WALL, M_WALL, M_WALL2, RVC, B_NUMBER, &
           MU_AIR, SC_AIR, TMP_N2, M_DOT, M_VAP, Y_PLUS, Y_S_PLUS, GAMMA, RHOCBAR, MCBAR, H_L_1, H_L_2
REAL(EB), POINTER, DIMENSION(:,:,:) :: RHO_INTERIM,TMP_INTERIM
REAL(EB), POINTER, DIMENSION(:,:,:,:) :: ZZ_INTERIM
TYPE (SPECIES_TYPE), POINTER :: SS=>NULL()
TYPE (SURFACE_TYPE), POINTER :: SF=>NULL()
TYPE (SPECIES_MIXTURE_TYPE), POINTER :: SM=>NULL(), SM2=>NULL()
TYPE(WALL_TYPE), POINTER :: WC
!TYPE(CFACE_TYPE), POINTER :: CFA
TYPE(BOUNDARY_ONE_D_TYPE), POINTER :: ONE_D
TYPE(BOUNDARY_PROP1_TYPE), POINTER :: B1
TYPE(BOUNDARY_PROP2_TYPE), POINTER :: B2
TYPE(BOUNDARY_COORD_TYPE), POINTER :: BC

CALL POINT_TO_MESH(NM)

ZZ_INTERIM=> SCALAR_WORK1
ZZ_INTERIM = ZZ
RHO_INTERIM => WORK1
RHO_INTERIM = RHO
TMP_INTERIM => WORK2
TMP_INTERIM = TMP

DO IW=1,N_EXTERNAL_WALL_CELLS+N_INTERNAL_WALL_CELLS
   WC => WALL(IW)
   B1 => BOUNDARY_PROP1(WC%B1_INDEX)
   B1%Q_CONDENSE = 0._EB
ENDDO

SPEC_LOOP: DO NS = 1, N_TRACKED_SPECIES
   SM => SPECIES_MIXTURE(NS)
   IF (.NOT. SM%CONDENSATION_SMIX_INDEX > 0) CYCLE SPEC_LOOP
   Z_COND_INDEX = SM%CONDENSATION_SMIX_INDEX
   SM2 => SPECIES_MIXTURE(SM%CONDENSATION_SMIX_INDEX)
   Y_INDEX = SM2%SINGLE_SPEC_INDEX
   SS => SPECIES(Y_INDEX)
   CALL INTERPOLATE1D_UNIFORM(LBOUND(SS%H_V,1),SS%H_V,SS%TMP_V,H_V_B)

   ! Gas Phase

   DO K = 1, KBAR
      DO J = 1, JBAR
         ILOOP: DO I = 1, IBAR
            IF (CELL(CELL_INDEX(I,J,K))%SOLID) CYCLE ILOOP
            IF (CC_IBM) THEN
               IF (CCVAR(I,J,K,CC_CGSC) /= CC_GASPHASE) CYCLE ILOOP
            ENDIF

            ZZ_GET(1:N_TRACKED_SPECIES) = ZZ_INTERIM(I,J,K,1:N_TRACKED_SPECIES)
            IF (ZZ_GET(NS) < ZZ_MIN_GLOBAL .AND. ZZ_GET(Z_COND_INDEX) < ZZ_MIN_GLOBAL) CYCLE ILOOP
            DHOR = H_V_B*SS%MW/R0

            P_RATIO = PBAR(0,PRESSURE_ZONE(I,J,K))/P_STP

            TMP_G = TMP(I,J,K)
            RHO_G = RHO(I,J,K)
            ! Boiling temperature at current background pressure
            T_BOIL_EFF = MAX(0._EB,DHOR*SS%TMP_V/(DHOR-SS%TMP_V*LOG(P_RATIO)+TWO_EPSILON_EB))

            CALL INTERPOLATE1D_UNIFORM(LBOUND(SS%H_V,1),SS%H_V,TMP_G,H_V)
            CALL INTERPOLATE1D_UNIFORM(LBOUND(SS%H_V,1),SS%H_V,T_BOIL_EFF,H_V_B)
            H_V_A = 0.5_EB*(H_V+H_V_B)

            CALL GET_MASS_FRACTION_ALL(ZZ_GET,Y_ALL)
            Y_GAS = Y_ALL(Y_INDEX)
            Y_COND = ZZ_GET(Z_COND_INDEX)

            ! Determine the ratio of molecular weights between the gas and droplet vapor

            MW_GAS = 0._EB
            IF (ABS(Y_GAS-1._EB) > TWO_EPSILON_EB) THEN
               DO NS2=1,N_SPECIES
                  IF (NS2==Y_INDEX) CYCLE
                  MW_GAS = MW_GAS + Y_ALL(NS2)/SPECIES(NS2)%MW
               ENDDO
               IF (MW_GAS<=TWO_EPSILON_EB) THEN
                  MW_GAS=SPECIES_MIXTURE(1)%MW
               ELSE
                  MW_GAS = (1._EB-Y_GAS)/MW_GAS
               ENDIF
            ELSE
               MW_GAS=SPECIES_MIXTURE(1)%MW
            ENDIF
            MW_RATIO = MW_GAS/SS%MW
            Y_GAS = Y_GAS - Y_COND

            DHOR = H_V_A*SS%MW/R0
            ! Compute equilibrium vapor mass fraction
            X_CLOUD  = MIN(1._EB,EXP(DHOR*(1._EB/T_BOIL_EFF-1._EB/TMP_G)))
            Y_CLOUD  = X_CLOUD/(MW_RATIO + (1._EB-MW_RATIO)*X_CLOUD)
            RVC = RDX(I)*RRN(I)*RDY(J)*RDZ(K)
            IF (Y_GAS > Y_CLOUD) THEN
               IF (ZZ_INTERIM(I,J,K,NS) < ZZ_MIN_GLOBAL) CYCLE ILOOP
               Y_1 = MAX(Y_CLOUD,Y_GAS-ZZ_INTERIM(I,J,K,NS))
               Y_2 = Y_GAS
               Y_N = 0.5_EB*(Y_1+Y_2)
            ELSE
               IF (Y_COND < ZZ_MIN_GLOBAL) CYCLE ILOOP
               Y_1 = Y_GAS
               Y_2 = MIN(Y_CLOUD,Y_GAS+Y_COND)
               Y_N = 0.5_EB*(Y_1+Y_2)
            ENDIF

            CALL GET_SPECIFIC_HEAT(ZZ_GET,CP,TMP_G)
            TMP_N = TMP_G
            EVAP_LOOP: DO
               TMP_N2 = TMP_N
               TMP_N = (Y_GAS-Y_N)*H_V/CP+TMP_G
               IF (ABS(TMP_N - TMP_N2)<1.E-2_EB) EXIT EVAP_LOOP
               CALL INTERPOLATE1D_UNIFORM(LBOUND(SS%H_V,1),SS%H_V,TMP_N,H_V_N)
               H_V_A = 0.5_EB*(H_V_N+H_V_B)
               X_GUESS  = MIN(1._EB,EXP(H_V_A*SS%MW/R0*(1._EB/T_BOIL_EFF-1._EB/TMP_N)))
               Y_GUESS  = X_GUESS/(MW_RATIO + (1._EB-MW_RATIO)*X_GUESS)
               Y_NN = Y_N
               IF (Y_GUESS >= Y_N) THEN
                  Y_1 = Y_N
                  Y_N = 0.5_EB*(Y_N+Y_2)
               ELSE
                  Y_2 = Y_N
                  Y_N = 0.5_EB*(Y_N+Y_1)
               ENDIF
               IF (ABS(Y_NN-Y_N)/Y_N < 1.E-4_EB) EXIT EVAP_LOOP
            ENDDO EVAP_LOOP

            ! Limit based on evaporation rate (assume condensation has same mass transfer number)
            D_AIR = D_Z(NINT(TMP_G),NS)
            H_MASS = 2._EB*D_AIR/SM%MEAN_DIAMETER
            N_PART = Y_COND * RHO_G / (FOTHPI* SS%DENSITY_LIQUID * (0.5_EB*SM%MEAN_DIAMETER)**3)
            N_PART = MAX(NUCLEATION_SITES,N_PART)
            B_NUMBER = LOG(1._EB + ABS(Y_CLOUD - Y_GAS) / MAX(DY_MIN_BLOWING, (1._EB - Y_CLOUD)))
            Y_1 = ZZ_INTERIM(I,J,K,NS)
            IF (Y_GAS < Y_CLOUD) THEN
               ZZ_INTERIM(I,J,K,NS) = ZZ_INTERIM(I,J,K,NS) + &
                                      MIN(Y_N-Y_GAS,H_MASS*N_PART*4._EB*PI*(0.5_EB*SM%MEAN_DIAMETER)**2*B_NUMBER*DT/RHO_G)
            ELSE
               ZZ_INTERIM(I,J,K,NS) = ZZ_INTERIM(I,J,K,NS) - &
                                      MIN(Y_GAS-Y_N,H_MASS*N_PART*4._EB*PI*(0.5_EB*SM%MEAN_DIAMETER)**2*B_NUMBER*DT/RHO_G)
            ENDIF
            Y_2 = ZZ_INTERIM(I,J,K,NS)
            ZZ_INTERIM(I,J,K,Z_COND_INDEX) = ZZ_INTERIM(I,J,K,Z_COND_INDEX)-(Y_2-Y_1)
            TMP_INTERIM(I,J,K) = TMP_INTERIM(I,J,K) - (Y_2-Y_1)*H_V/CP
            M_DOT_PPP(I,J,K,NS) = M_DOT_PPP(I,J,K,NS) + RHO_G*(Y_2-Y_1)/DT
            M_DOT_PPP(I,J,K,Z_COND_INDEX) = M_DOT_PPP(I,J,K,Z_COND_INDEX) - RHO_G*(Y_2-Y_1)/DT
            D_SOURCE(I,J,K) = D_SOURCE(I,J,K) - (Y_2-Y_1)*H_V/(CP*TMP_G*DT)
         ENDDO ILOOP
      ENDDO
   ENDDO

   ! Solid Phase

   WALL_LOOP: DO IW=1,N_EXTERNAL_WALL_CELLS+N_INTERNAL_WALL_CELLS
      WC=>WALL(IW)
      B1 => BOUNDARY_PROP1(WC%B1_INDEX)
      IF (WC%BOUNDARY_TYPE /= SOLID_BOUNDARY .OR. B1%NODE_INDEX > 0) CYCLE WALL_LOOP
      B2 => BOUNDARY_PROP2(WC%B2_INDEX)
      BC => BOUNDARY_COORD(WC%BC_INDEX)
      I = BC%IIG
      J = BC%JJG
      K = BC%KKG
      IF (B1%AWM_AEROSOL(SS%AWM_INDEX) < TWO_EPSILON_EB .AND. ZZ_INTERIM(I,J,K,NS) < ZZ_MIN_GLOBAL) CYCLE WALL_LOOP

      DHOR = H_V_B*SS%MW/R0
      P_RATIO = PBAR(0,PRESSURE_ZONE(I,J,K))/P_STP

      ! Boiling temperature at current background pressure
      T_BOIL_EFF = MAX(0._EB,DHOR*SS%TMP_V/(DHOR-SS%TMP_V*LOG(P_RATIO)+TWO_EPSILON_EB))

      CALL INTERPOLATE1D_UNIFORM(LBOUND(SS%H_V,1),SS%H_V,B1%TMP_F,H_V)
      CALL INTERPOLATE1D_UNIFORM(LBOUND(SS%H_V,1),SS%H_V,T_BOIL_EFF,H_V_B)
      H_V_A = 0.5_EB*(H_V+H_V_B)

      TMP_G = TMP_INTERIM(I,J,K)
      CALL INTERPOLATE1D_UNIFORM(LBOUND(SS%H_V,1),SS%H_V,TMP_G,H_V)
      CALL INTERPOLATE1D_UNIFORM(LBOUND(SS%H_L,1),SS%H_L,TMP_G,H_L_1)
      RHO_G = RHO_INTERIM(I,J,K)
      TMP_W = B1%TMP_F
      ITMP = MIN(I_MAX_TEMP,NINT(TMP_W))
      CALL INTERPOLATE1D_UNIFORM(LBOUND(SS%H_L,1),SS%H_L,TMP_W,H_L_2)

      ZZ_GET(1:N_TRACKED_SPECIES) = ZZ_INTERIM(I,J,K,1:N_TRACKED_SPECIES)

      ! Determine the ratio of molecular weights between the gas and droplet vapor
      CALL GET_MASS_FRACTION_ALL(ZZ_GET,Y_ALL)
      Y_GAS = Y_ALL(Y_INDEX)
      Y_COND = ZZ_GET(Z_COND_INDEX)
      MW_GAS = 0._EB
      IF (ABS(Y_GAS-1._EB) > TWO_EPSILON_EB) THEN
         DO NS2=1,N_SPECIES
            IF (NS2==Y_INDEX) CYCLE
            MW_GAS = MW_GAS + Y_ALL(NS2)/SPECIES(NS2)%MW
         ENDDO
         IF (MW_GAS<=TWO_EPSILON_EB) THEN
            MW_GAS=SPECIES_MIXTURE(1)%MW
         ELSE
            MW_GAS = (1._EB-Y_GAS)/MW_GAS
         ENDIF
      ELSE
         MW_GAS=SPECIES_MIXTURE(1)%MW
      ENDIF
      MW_RATIO = MW_GAS/SS%MW
      Y_GAS = Y_GAS - Y_COND
      DHOR = H_V_A*SS%MW/R0

      ! Compute equilibrium vapor mass fraction
      X_WALL  = MIN(1._EB,EXP(DHOR*(1._EB/T_BOIL_EFF-1._EB/TMP_W)))
      Y_WALL  = X_WALL/(MW_RATIO + (1._EB-MW_RATIO)*X_WALL)
      M_WALL = B1%AWM_AEROSOL(SS%AWM_INDEX) * B1%AREA
      RVC = RDX(I)*RRN(I)*RDY(J)*RDZ(K)

      IF(Y_GAS > Y_WALL) THEN
         IF (ZZ_GET(NS) < ZZ_MIN_GLOBAL) CYCLE WALL_LOOP
         Y_1 = MAX(Y_WALL,Y_GAS-ZZ_GET(NS))
         Y_2 = Y_GAS
         Y_N = 0.5_EB*(Y_1+Y_2)
      ELSE
         IF (B1%AWM_AEROSOL(SS%AWM_INDEX) < TWO_EPSILON_EB) CYCLE WALL_LOOP
         Y_1 = Y_GAS
         Y_2 = MIN(Y_WALL, (Y_GAS*RHO_G+M_WALL*RVC)/(RHO_G+M_WALL*RVC))
         Y_N = 0.5_EB*(Y_1+Y_2)
      ENDIF

      ! Compute mdot Paper CFD4NRS-2016
      CALL GET_VISCOSITY(ZZ_GET,MU_AIR,TMP_G)
      D_AIR = D_Z(NINT(TMP_G),NS)
      SC_AIR = MU_AIR/(RHO_G*D_AIR)
      Y_PLUS = RHO_G*MAX(0.0001_EB,B2%U_TAU)*0.5_EB/(B1%RDN*MU_AIR) ! FDS Tech Guide (8.36)
      GAMMA = 0.01_EB*(SC_AIR*Y_PLUS)**4/(1._EB+5._EB*SC_AIR**3*Y_PLUS) ! FDS Tech Guide (8.38)
      Y_S_PLUS = SC_AIR*Y_PLUS*EXP(-GAMMA) + &
                 (2.12_EB*LOG(Y_PLUS)+(3.85_EB*SC_AIR**ONTH-1.3_EB)**2+2.12_EB*LOG(SC_AIR)) * EXP(-1._EB/GAMMA) ! (8.37)
      ! Find equlibrium
      IF (SURFACE(WC%SURF_INDEX)%THERMAL_BC_INDEX==THERMALLY_THICK) THEN
         ONE_D=>BOUNDARY_ONE_D(WC%OD_INDEX)
         SF=>SURFACE(WC%SURF_INDEX)
         RHOCBAR = 0._EB
         DO NMAT=1,SF%N_MATL
            IF (ONE_D%MATL_COMP(NMAT)%RHO(1)<=TWO_EPSILON_EB) CYCLE
            RHOCBAR = RHOCBAR + ONE_D%MATL_COMP(NMAT)%RHO(1)*MATERIAL(SF%MATL_INDEX(NMAT))%C_S(ITMP)
         ENDDO
         MCBAR = RHOCBAR*B1%AREA*(ONE_D%X(1)-ONE_D%X(0))

         TMP_N = TMP_W
         EVAP_LOOP_2: DO
            TMP_N2 = TMP_N
            TMP_N = TMP_W + ((Y_GAS-Y_N)*RHO_G/RVC)*(H_V+H_L_1-H_L_2)/MCBAR
            IF (ABS(TMP_N2- TMP_N)<1.E-2_EB) EXIT EVAP_LOOP_2
            CALL INTERPOLATE1D_UNIFORM(LBOUND(SS%H_V,1),SS%H_V,TMP_N,H_V_N)
            CALL INTERPOLATE1D_UNIFORM(LBOUND(SS%H_L,1),SS%H_L,TMP_N,H_L_2)
            H_V_A = 0.5_EB*(H_V_N+H_V_B)
            X_GUESS  = MIN(1._EB,EXP(H_V_A*SS%MW/R0*(1._EB/T_BOIL_EFF-1._EB/TMP_N)))
            Y_GUESS  = X_GUESS/(MW_RATIO + (1._EB-MW_RATIO)*X_GUESS)
            Y_NN = Y_N
            IF (Y_GUESS > Y_N) THEN
               Y_1 = Y_N
               Y_N = 0.5_EB*(Y_N+Y_2)
            ELSE
               Y_2 = Y_N
               Y_N = 0.5_EB*(Y_N+Y_1)
            ENDIF
            IF (ABS(Y_NN-Y_N)/Y_N < 1.E-4_EB) EXIT EVAP_LOOP_2
         ENDDO EVAP_LOOP_2
      ELSE
         IF (Y_GAS > Y_WALL) THEN
            Y_N = Y_1
         ELSE
            Y_N = Y_2
         ENDIF
      ENDIF

      ! Limit based on evaporation rate (assume condensation has same mass transfer number)
      ZZ_INTERIM(I,J,K,:) = ZZ_INTERIM(I,J,K,:) * RHO_G
      IF (Y_GAS > Y_WALL) THEN
         M_DOT = RHO_G*MAX(0.0001_EB,B2%U_TAU)*(Y_GAS-Y_WALL)/Y_S_PLUS
         M_VAP = -MIN((Y_GAS-Y_N)*RHO_G/(RVC*(1._EB-Y_N)),M_DOT*B1%AREA*DT)
      ELSE
         M_DOT = RHO_G*MAX(0.0001_EB,B2%U_TAU)*(Y_WALL-Y_GAS)/Y_S_PLUS
         M_VAP = MIN((Y_N-Y_GAS)*RHO_G/(RVC*(1._EB-Y_N)),M_DOT*B1%AREA*DT)
      ENDIF

      ZZ_INTERIM(I,J,K,NS) = ZZ_INTERIM(I,J,K,NS)+M_VAP*RVC
      RHO_INTERIM(I,J,K) = SUM(ZZ_INTERIM(I,J,K,:))
      ZZ_INTERIM(I,J,K,:) = ZZ_INTERIM(I,J,K,:)/RHO_INTERIM(I,J,K)
      M_WALL2 = M_WALL - M_VAP
      CALL GET_MOLECULAR_WEIGHT(ZZ_GET,MW_GAS)
      D_SOURCE(I,J,K) = D_SOURCE(I,J,K) + M_VAP*MW_GAS/SS%MW*RVC/(RHO_G*DT)
      M_DOT_PPP(I,J,K,NS) = M_DOT_PPP(I,J,K,NS) + M_VAP*RVC/DT
      ZZ_INTERIM(I,J,K,:) = ZZ_INTERIM(I,J,K,:)/SUM(ZZ_INTERIM(I,J,K,:))
      IF (SM2%AWM_INDEX > 0) B1%AWM_AEROSOL(SM2%AWM_INDEX) = M_WALL2/B1%AREA
      IF (SS%AWM_INDEX > 0)  B1%AWM_AEROSOL(SS%AWM_INDEX)  = M_WALL2/B1%AREA
      B1%Q_CONDENSE = -M_VAP * (H_V+H_L_1-H_L_2)/(B1%AREA*DT)
   ENDDO WALL_LOOP
ENDDO SPEC_LOOP

END SUBROUTINE CONDENSATION_EVAPORATION


!> \brief Calculate fall-off function 
!> \param TMP is the current temperature.
!> \param P_RI is the reduced pressure
!> \param RN is the reaction

REAL(EB) FUNCTION CALC_FCENT(TMP, P_RI, I)
REAL(EB), INTENT(IN) :: TMP, P_RI
INTEGER, INTENT(IN) :: I
TYPE(REACTION_TYPE), POINTER :: RN => NULL()
REAL(EB) :: LOGFCENT, C, N, LOGPRC
REAL(EB), PARAMETER :: D=0.14_EB

RN=>REACTION(I)
IF(RN%REACTYPE==FALLOFF_TROE_TYPE) THEN
   IF (RN%T2_TROE <-1.E20_EB) THEN
      LOGFCENT = LOG10(MAX((1 - RN%A_TROE)*EXP(-TMP*RN%RT3_TROE) + &
                 RN%A_TROE*EXP(-TMP*RN%RT1_TROE),TWO_EPSILON_EB))
   ELSE
      LOGFCENT = LOG10(MAX((1 - RN%A_TROE)*EXP(-TMP*RN%RT3_TROE) + &
                 RN%A_TROE*EXP(-TMP*RN%RT1_TROE) + EXP(-RN%T2_TROE/TMP),TWO_EPSILON_EB))
   ENDIF
   C = -0.4_EB - 0.67_EB*LOGFCENT
   N = 0.75_EB - 1.27_EB*LOGFCENT
   LOGPRC = LOG10(MAX(P_RI, TWO_EPSILON_EB)) + C
   CALC_FCENT = 10._EB**(LOGFCENT/(1._EB + (LOGPRC/(N - D*LOGPRC))**2))
ELSE
   CALC_FCENT = 1._EB  !FALLOFF-LINDEMANNN
ENDIF

RETURN

END FUNCTION CALC_FCENT

END MODULE FIRE

